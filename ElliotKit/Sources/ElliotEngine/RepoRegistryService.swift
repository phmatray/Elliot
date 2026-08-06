import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation

/// What one sweep did, and — the part that matters — what it did not.
///
/// `skipped` holds **every** row the sweep left out, each with the reason it was
/// left out. A repository dropped silently from a sweep reads exactly like one
/// that succeeded; the portfolio has paid for that once already, when a probe
/// that `continue`d past its errors reported 148 repositories where 210 were
/// eligible and the missing 62 were invisible.
public struct SyncSummary: Sendable {
    public let attempted: Int
    public let succeeded: Int
    /// (row id, why it was not attempted) — for every row left out.
    public let skipped: [(String, String)]
    /// (row id, why the pull failed) — attempted, and refused by git.
    public let failed: [(String, String)]

    public init(
        attempted: Int, succeeded: Int,
        skipped: [(String, String)], failed: [(String, String)]
    ) {
        self.attempted = attempted
        self.succeeded = succeeded
        self.skipped = skipped
        self.failed = failed
    }

    /// The sentence the status bar shows. `failed` appears only when there is
    /// one, so a clean sweep does not advertise a zero.
    public var sentence: String {
        "\(succeeded) pulled · \(skipped.count) skipped"
            + (failed.isEmpty ? "" : " · \(failed.count) failed")
    }
}

public struct RepoFixOutcome: Sendable, Hashable {
    public let succeeded: Bool
    public let detail: String

    public init(succeeded: Bool, detail: String) {
        self.succeeded = succeeded
        self.detail = detail
    }
}

/// Assembles the Repositories page's rows, and applies exactly one fix.
///
/// One at a time is deliberate: `move` relocates a directory in the user's
/// portfolio, and a batch that half-succeeded would leave the store pointing at
/// paths that no longer exist, with no record of which ones.
public struct RepoRegistryService: Sendable {
    private let store: BoardStore
    private let gh: GHClient
    private let git: GitClient

    public init(store: BoardStore, config: ToolConfig) {
        self.store = store
        self.gh = GHClient(config: config)
        self.git = GitClient(config: config)
    }

    public func rows(layout: RepoTreeLayout) async -> [RepoRow] {
        let gh = self.gh
        let remotes = await withTaskGroup(of: [GHRepoSummary].self) { group in
            for owner in layout.owners {
                group.addTask { (try? await gh.repos(owner: owner)) ?? [] }
            }
            return await group.reduce(into: [GHRepoSummary]()) { $0 += $1 }
        }
        return RepoReconciler.rows(
            github: remotes,
            disk: RepoTreeScanner(layout: layout).scan(),
            registered: (try? await store.repos()) ?? [],
            layout: layout)
    }

    public func apply(_ fix: RepoFix, layout: RepoTreeLayout) async -> RepoFixOutcome {
        do {
            switch fix {
            case .clone(let nameWithOwner, let into):
                try await git.clone(nameWithOwner: nameWithOwner, into: into)
                return try await register(path: into, layout: layout)

            case .register(let path):
                return try await register(path: path, layout: layout)

            case .pull(let path):
                // `--ff-only`, so this refuses itself on a tree the probe raced
                // and found work in. The row's button and the Sync sweep reach
                // the same verb rather than two spellings of "pull".
                try await git.pullFastForward(cwd: path)
                return RepoFixOutcome(
                    succeeded: true,
                    detail: "Fast-forwarded \((path as NSString).lastPathComponent).")

            case .move(let from, let to):
                try git.relocate(from: from, to: to)
                // Repoint in the same step: a store pointing at a path that was
                // moved out from under it is worse than an unregistered clone,
                // because nothing on the page would say so.
                if var repo = try await store.repo(path: from) {
                    repo.path = to
                    repo.visibility = layout.slot(forPath: to)?.visibility ?? repo.visibility
                    try await store.saveRepo(repo)
                }
                return RepoFixOutcome(succeeded: true, detail: "Moved to \(to).")

            case .forget(let repoID):
                // The disk is untouched, but the *board* is not: `card.repoID`
                // cascades, so this drops the repository's cards, runs, analyses
                // and proposals. Saying only "the clone is untouched" would be
                // true and misleading.
                try await store.deleteRepo(id: repoID)
                return RepoFixOutcome(
                    succeeded: true,
                    detail: "Forgotten, with its cards. The clone on disk is untouched.")
            }
        } catch {
            // Name the act that failed. A bare `localizedDescription` beside a
            // row of buttons does not say which button produced it.
            return RepoFixOutcome(
                succeeded: false,
                detail: "Could not \(fix.label.lowercased()): \(error.localizedDescription)"
            )
        }
    }

    /// Mirrors `AppModel.addRepo(path:)`, plus the visibility the path implies.
    private func register(path: String, layout: RepoTreeLayout) async throws -> RepoFixOutcome {
        guard FileManager.default.fileExists(atPath: path + "/.git") else {
            return RepoFixOutcome(succeeded: false, detail: "\(path) is not a git repository.")
        }
        let slot = layout.slot(forPath: path)
        let info = try? await gh.repoInfo(cwd: path)
        let repo = Repo(
            path: path,
            nameWithOwner: info?.nameWithOwner ?? slot?.nameWithOwner
                ?? URL(fileURLWithPath: path).lastPathComponent,
            defaultBranch: info?.defaultBranch ?? "main",
            displayName: URL(fileURLWithPath: path).lastPathComponent,
            visibility: slot?.visibility)
        try await store.saveRepo(repo)
        return RepoFixOutcome(succeeded: true, detail: "Registered \(repo.nameWithOwner).")
    }

    /// Refines the rows the reconciler called `.ok` with what git says about
    /// each clone. Every other row is returned exactly as it arrived.
    ///
    /// Eight in flight, matching `repo-audit/repo_sync.py`: each item is a fetch
    /// plus three subprocesses, and 221 of those at once would swamp the machine.
    /// The result stays in **input order** — the page renders rows in place, so a
    /// completion-ordered result would make every refresh jump.
    public func probe(_ rows: [RepoRow]) async -> [RepoRow] {
        await withTaskGroup(of: (Int, RepoRow).self) { group in
            var result = rows
            // Start 8, then add one more each time one finishes: the window stays
            // at 8 in flight rather than 8 per wave, so one slow fetch does not
            // idle seven workers.
            let limit = min(8, rows.count)
            for index in 0..<limit {
                group.addTask { (index, await self.refine(rows[index])) }
            }
            var next = limit
            while let (index, row) = await group.next() {
                result[index] = row
                if next < rows.count {
                    let pending = next
                    group.addTask { (pending, await self.refine(rows[pending])) }
                    next += 1
                }
            }
            return result
        }
    }

    private func refine(_ row: RepoRow) async -> RepoRow {
        guard row.issue == .ok, let path = row.path else { return row }
        let issue = await classify(path: path)
        var refined = row
        refined.issue = issue
        refined.detail = Self.explain(issue, path: path)
        refined.fixes = issue.isBehind ? [.pull(path: path)] : []
        return refined
    }

    /// One clone's git state. Ordered most-blocking first: the first answer wins,
    /// so a tree with local work is never reported as merely `.behind`. Reverse
    /// any two of these and a clone carrying uncommitted work becomes eligible
    /// for the sweep.
    private func classify(path: String) async -> RepoIssue {
        guard await git.isMainCheckout(path: path) else { return .outOfScope(.otherRoot) }
        if await git.isDetached(cwd: path) { return .detached }
        if !(await git.isClean(cwd: path)) { return .dirty }
        // Before the counts, never after: `aheadBehind` reads `@{u}`, a local
        // ref, and answers `behind: 0` for a clone that has never been told.
        do { try await git.fetch(cwd: path) } catch { return .unreadable("fetch failed") }
        guard let counts = await git.aheadBehind(cwd: path) else { return .noRemote }
        switch (counts.ahead, counts.behind) {
        case (0, 0): return .ok
        case (0, let behind): return .behind(by: behind)
        case (_, 0): return .ahead
        default: return .diverged
        }
    }

    /// Fast-forwards every row that is strictly behind, eight at a time.
    ///
    /// Only `.behind`, and only `--ff-only`: every action in this batch refuses
    /// itself when it is not safe, which is what makes a batch legitimate here
    /// at all. `move` is not in it and cannot be — a `moveItem` does not refuse.
    ///
    /// It sweeps the rows it is given rather than re-probing first, so what the
    /// user saw on screen is what gets swept.
    public func syncAll(rows: [RepoRow]) async -> SyncSummary {
        var pullable: [(id: String, path: String)] = []
        var skipped: [(String, String)] = []
        for row in rows {
            if row.issue.isBehind, let path = row.path {
                pullable.append((row.id, path))
            } else {
                skipped.append((row.id, Self.whyNotSwept(row)))
            }
        }

        var succeeded = 0
        var failed: [(String, String)] = []
        await withTaskGroup(of: (String, String?).self) { group in
            let limit = min(8, pullable.count)
            for index in 0..<limit {
                let target = pullable[index]
                group.addTask { (target.id, await self.pull(target.path)) }
            }
            var next = limit
            while let (id, error) = await group.next() {
                if let error { failed.append((id, error)) } else { succeeded += 1 }
                if next < pullable.count {
                    let target = pullable[next]
                    group.addTask { (target.id, await self.pull(target.path)) }
                    next += 1
                }
            }
        }

        return SyncSummary(
            attempted: pullable.count, succeeded: succeeded,
            skipped: skipped, failed: failed)
    }

    /// nil on success, the reason on failure.
    private func pull(_ path: String) async -> String? {
        do {
            try await git.pullFastForward(cwd: path)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Never empty. The row's own detail when it has one, and otherwise a
    /// sentence — because "skipped, reason blank" is the silence this whole
    /// summary exists to prevent.
    private static func whyNotSwept(_ row: RepoRow) -> String {
        if !row.detail.isEmpty { return row.detail }
        if row.issue.isBehind, row.path == nil {
            return "Behind, but Elliot holds no path for it."
        }
        return "Not behind."
    }

    private static func explain(_ issue: RepoIssue, path: String) -> String {
        switch issue {
        case .ok: "Up to date."
        case .behind(let count): "\(count) commit(s) behind; a fast-forward will do."
        case .dirty: "Uncommitted changes — left alone."
        case .ahead: "Local commits not pushed — left alone."
        case .diverged: "Diverged from the upstream — needs a human."
        case .detached: "Detached HEAD — left alone."
        case .noRemote: "No upstream branch to compare against."
        case .unreadable(let why): "Could not read this clone: \(why)."
        case .outOfScope(.otherRoot): "A linked worktree — never swept."
        default: path
        }
    }
}
