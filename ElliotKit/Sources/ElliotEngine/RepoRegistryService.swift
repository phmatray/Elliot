import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation

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
            return RepoFixOutcome(succeeded: false, detail: error.localizedDescription)
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
}
