import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation

public struct ImportSummary: Sendable, Equatable {
    public var repoName: String
    public var created = 0
    public var adopted = 0
    public var moved = 0
    public var unchanged = 0
    public var skippedDismissed = 0
    /// Set when `gh` or a write failed. The pass over other repositories
    /// continues regardless — one unreachable repository is not a reason to
    /// leave the rest unrefreshed.
    public var failure: String?

    public init(repoName: String) { self.repoName = repoName }

    /// What the status bar says.
    public var sentence: String {
        if let failure { return "\(repoName) — could not refresh: \(failure)" }
        var parts = ["\(created) new", "\(adopted) updated", "\(unchanged) unchanged"]
        if skippedDismissed > 0 { parts.append("\(skippedDismissed) dismissed") }
        return "\(repoName) — " + parts.joined(separator: " · ")
    }
}

/// Brings a repository's GitHub issues and pull requests onto the board.
///
/// Read-only towards GitHub: it lists, it never creates, closes or comments.
/// The judgement is `GitHubImporter`'s; this fetches, applies and counts.
public actor GitHubImportService {
    private let store: BoardStore
    private let gh: GHClient
    private let board: BoardService

    public init(store: BoardStore, gh: GHClient, board: BoardService) {
        self.store = store
        self.gh = gh
        self.board = board
    }

    public func importRepo(_ repo: Repo) async -> ImportSummary {
        var summary = ImportSummary(repoName: repo.displayName)
        do {
            let issues = try await gh.issues(repo: repo.nameWithOwner, limit: 100)
            let prs = try await gh.pullRequests(repo: repo.nameWithOwner, limit: 100)
            let cards = try await store.cards(repoID: repo.id)
            let dismissed = try await store.dismissals(repoID: repo.id)

            // Open work only: closed items no card already tracks are history,
            // not a backlog, and importing them would make Done a graveyard.
            let knownIssues = Set(cards.compactMap(\.issueNumber))
            let knownPRs = Set(cards.compactMap(\.prNumber))

            let plan = GitHubImporter.plan(
                repoID: repo.id,
                issues: issues.filter { !$0.isClosed || knownIssues.contains($0.number) },
                pullRequests: prs.filter { $0.isOpen || knownPRs.contains($0.number) },
                existingCards: cards,
                dismissed: dismissed,
                now: Date())
            summary.skippedDismissed = plan.skippedDismissed

            for action in plan.actions {
                switch action {
                case .create(let seed):
                    try await board.adoptCard(seed)
                    summary.created += 1

                case .adopt(let cardID, let fields, let moveTo):
                    guard var card = try await store.card(id: cardID) else { continue }
                    card.title = fields.title
                    card.body = fields.body
                    card.issueNumber = fields.issueNumber
                    card.issueURL = fields.issueURL
                    card.prNumber = fields.prNumber
                    card.prURL = fields.prURL
                    card.branch = fields.branch
                    card.updatedAt = Date()
                    try await store.saveCard(card)
                    summary.adopted += 1

                    if let moveTo {
                        // Through the funnel, with a system reason: the rule
                        // engine maps every system origin to `.noAction`, so a
                        // card landing in In Review cannot fire `merge-pr`.
                        await board.applySystemMove(cardID: cardID, to: moveTo, reason: .githubImport)
                        summary.moved += 1
                    }

                case .unchanged:
                    summary.unchanged += 1
                }
            }
        } catch {
            summary.failure = error.localizedDescription
        }
        return summary
    }

    /// One repository at a time. Serial on purpose: `gh` is a subprocess per
    /// call and the write path is a single SQLite writer, so concurrency here
    /// would buy nothing and cost a lock.
    public func importAll(_ repos: [Repo]) async -> [ImportSummary] {
        var summaries: [ImportSummary] = []
        for repo in repos where repo.isEnabled {
            summaries.append(await importRepo(repo))
        }
        return summaries
    }
}
