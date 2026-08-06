import Foundation

/// Why a repository's row is not simply fine.
///
/// Only the verdicts this reconciler can produce live here. Git state — behind,
/// dirty, diverged — arrives with the sync follow-up, which refines a row rather
/// than changing how rows are built.
public enum RepoIssue: Sendable, Hashable {
    case ok
    case notCloned
    case notRegistered
    case missing
    case misplaced(expected: String)

    /// On disk, registered, and absent from GitHub's answer.
    ///
    /// Its own case rather than `.ok` with a telling detail, because `.ok` is
    /// the verdict nobody scrolls to read and this row has at least three
    /// causes, none of them "fine": the repository was renamed or transferred,
    /// so the local remote is stale; it was deleted, so this clone is the only
    /// copy; or the listing itself was incomplete — pagination, a rate limit, a
    /// scope the token lacks.
    ///
    /// The third is what settles it. An incomplete answer is not a fact about
    /// the repository at all, and it would mark *many* rows at once. A row that
    /// says "fine" when the real answer is "I could not check" is a
    /// non-measurement rendered as a pass, which is the one thing this codebase
    /// spends its effort refusing to do.
    ///
    /// What it deliberately does **not** claim is *which* of the three happened.
    /// Telling "GitHub said no" from "GitHub did not answer" needs the scanner to
    /// report its own failure modes upward; the reconciler is pure and cannot
    /// ask. That is a separate change.
    case unlisted
    case outOfScope(OutOfScope)

    public enum OutOfScope: Sendable, Hashable { case fork, archived, otherRoot }
}

/// The one thing a row's button does. Nothing here deletes.
public enum RepoFix: Sendable, Hashable {
    case clone(nameWithOwner: String, into: String)
    case move(from: String, to: String)
    case register(path: String)
    case forget(repoID: UUID)

    /// The button's label. `move` names its destination, because it relocates a
    /// directory in the user's portfolio and must say so before it runs.
    public var label: String {
        switch self {
        case .clone: "Clone"
        case .move(_, let to): "Move to \((to as NSString).lastPathComponent)"
        case .register: "Register"
        case .forget: "Forget"
        }
    }
}

public struct RepoRow: Identifiable, Sendable, Hashable {
    public var id: String
    public var nameWithOwner: String?
    public var path: String?
    public var repoID: UUID?
    public var visibility: RepoVisibility?
    public var issue: RepoIssue
    public var detail: String
    public var fixes: [RepoFix]

    public init(
        id: String, nameWithOwner: String? = nil, path: String? = nil, repoID: UUID? = nil,
        visibility: RepoVisibility? = nil, issue: RepoIssue,
        detail: String = "", fixes: [RepoFix] = []
    ) {
        self.id = id
        self.nameWithOwner = nameWithOwner
        self.path = path
        self.repoID = repoID
        self.visibility = visibility
        self.issue = issue
        self.detail = detail
        self.fixes = fixes
    }
}

/// Turns GitHub, the disk and the store into one row per repository.
///
/// Pure by design: `ElliotApp` is an executable target with no tests, so the
/// judgement that a directory is in the wrong place — the one this feature acts
/// on by *moving* it — has to be provable here instead.
public enum RepoReconciler {
    public static func rows(
        github: [GHRepoSummary], disk: [RepoSlot],
        registered: [Repo], layout: RepoTreeLayout
    ) -> [RepoRow] {
        var byName: [String: RepoRow] = [:]
        let diskByName = Dictionary(disk.map { ($0.nameWithOwner, $0) }, uniquingKeysWith: { a, _ in a })
        let registeredByName = Dictionary(
            registered.map { ($0.nameWithOwner, $0) },
            uniquingKeysWith: { a, _ in a })

        for remote in github {
            byName[remote.nameWithOwner] = row(
                for: remote, disk: diskByName,
                registered: registeredByName, layout: layout)
        }

        // A clone or a registration GitHub did not mention still gets a row —
        // silence is how a repository disappears from a sweep unnoticed.
        //
        // Unregistered, the verdict stays `.notRegistered`: it is already
        // actionable and already carries its fix. Registered, it is `.unlisted`
        // and not `.ok` — nothing is wrong on disk, but nothing was confirmed
        // either, and those are different answers.
        for slot in disk where byName[slot.nameWithOwner] == nil {
            let path = "\(layout.root)/\(slot.owner)/\(slot.visibility.rawValue)/\(slot.name)"
            let known = registeredByName[slot.nameWithOwner]
            byName[slot.nameWithOwner] = RepoRow(
                id: slot.nameWithOwner, nameWithOwner: slot.nameWithOwner, path: path,
                repoID: known?.id, visibility: slot.visibility,
                issue: known == nil ? .notRegistered : .unlisted,
                detail: "On disk; GitHub did not list it.",
                fixes: known == nil ? [.register(path: path)] : [])
        }

        for repo in registered where byName[repo.nameWithOwner] == nil {
            let inTree = layout.slot(forPath: repo.path) != nil
            byName[repo.nameWithOwner] = RepoRow(
                id: repo.nameWithOwner, nameWithOwner: repo.nameWithOwner, path: repo.path,
                repoID: repo.id, issue: inTree ? .missing : .outOfScope(.otherRoot),
                detail: inTree
                    ? "Registered, but nothing is at \(repo.path)."
                    : "Registered outside \(layout.root)'s owner folders; left alone.",
                fixes: inTree ? [.forget(repoID: repo.id)] : [])
        }

        return byName.values.sorted { $0.id.lowercased() < $1.id.lowercased() }
    }

    private static func row(
        for remote: GHRepoSummary, disk: [String: RepoSlot],
        registered: [String: Repo], layout: RepoTreeLayout
    ) -> RepoRow {
        let name = remote.nameWithOwner
        let repo = registered[name]
        // The disk is the authority on presence: a slot exists only where the
        // scanner saw a `.git`. A registered path with no slot is *gone*, which
        // is a different row from one that was never cloned.
        let actual = disk[name].map { "\(layout.root)/\($0.owner)/\($0.visibility.rawValue)/\($0.name)" }

        if remote.isFork || remote.isArchived {
            return RepoRow(
                id: name, nameWithOwner: name, path: actual ?? repo?.path, repoID: repo?.id,
                visibility: remote.repoVisibility,
                issue: .outOfScope(remote.isFork ? .fork : .archived),
                detail: remote.isFork
                    ? "A fork — out of scope."
                    : "Archived on GitHub — out of scope.")
        }

        guard
            let expected = layout.expectedPath(
                nameWithOwner: name,
                visibility: remote.repoVisibility)
        else {
            return RepoRow(
                id: name, nameWithOwner: name, path: actual ?? repo?.path, repoID: repo?.id,
                visibility: remote.repoVisibility, issue: .outOfScope(.otherRoot),
                detail: "Owner \(name.split(separator: "/").first ?? "?") is not configured.")
        }

        guard let actual else {
            // Registered but absent is `.missing`, and its fix is to forget the
            // registration — never to clone on top of a path Elliot still holds.
            if let repo, layout.slot(forPath: repo.path) != nil {
                return RepoRow(
                    id: name, nameWithOwner: name, path: repo.path, repoID: repo.id,
                    visibility: remote.repoVisibility, issue: .missing,
                    detail: "Registered, but nothing is at \(repo.path).",
                    fixes: [.forget(repoID: repo.id)])
            }
            return RepoRow(
                id: name, nameWithOwner: name, repoID: repo?.id,
                visibility: remote.repoVisibility, issue: .notCloned,
                detail: "On GitHub, no clone under \(layout.root).",
                fixes: [.clone(nameWithOwner: name, into: expected)])
        }

        if actual != expected {
            return RepoRow(
                id: name, nameWithOwner: name, path: actual, repoID: repo?.id,
                visibility: remote.repoVisibility, issue: .misplaced(expected: expected),
                detail: "Cloned at \(actual); expected \(expected).",
                fixes: [.move(from: actual, to: expected)])
        }

        guard let repo else {
            return RepoRow(
                id: name, nameWithOwner: name, path: actual,
                visibility: remote.repoVisibility, issue: .notRegistered,
                detail: "Cloned in the right place; Elliot does not know it yet.",
                fixes: [.register(path: actual)])
        }

        return RepoRow(
            id: name, nameWithOwner: name, path: actual, repoID: repo.id,
            visibility: remote.repoVisibility, issue: .ok, detail: actual)
    }
}
