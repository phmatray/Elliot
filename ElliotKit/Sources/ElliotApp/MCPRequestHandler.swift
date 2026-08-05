import ElliotEngine
import ElliotIPC
import ElliotModel
import ElliotStore
import Foundation

/// Turns an IPC request into the same board calls a drag makes.
///
/// Nothing here decides anything: it resolves ids, calls `BoardService`, and
/// translates the answer back. The rules live in one place and this is not it.
public struct MCPRequestHandler: Sendable {
    private let store: BoardStore
    private let board: BoardService

    public init(store: BoardStore, board: BoardService) {
        self.store = store
        self.board = board
    }

    public func handle(_ request: ElliotRequest) async -> ElliotResponse {
        do {
            switch request {
            case .hello:
                return .ok(.hello(serverVersion: "\(elliotProtocolVersion)"))
            case .listCards(let repo, let column, let limit):
                return try await listCards(repo: repo, column: column, limit: limit)
            case .getCard(let id):
                return try await getCard(id)
            case .createCard(let repo, let title, let body, let story, let column):
                return try await createCard(repo: repo, title: title, body: body, story: story, column: column)
            case .moveCard(let id, let to, let followUps):
                return try await moveCard(id: id, to: to, followUps: followUps)
            case .listRuns(let cardID, let limit):
                let runs = try await store.runs(cardID: cardID, limit: limit)
                return .ok(.runs(runs.map(RunDTO.init)))
            }
        } catch let error as BoardError {
            switch error {
            case .cardNotFound(let id):
                return .failure(code: .cardNotFound, message: "No card with id \(id).", hint: nil)
            case .repoNotFound(let id):
                return .failure(code: .repoNotFound, message: "No repository \(id).", hint: nil)
            case .cardAlreadyFiled(let number):
                // Unreachable today — the wire has no update request. Mapped
                // rather than defaulted so that adding one surfaces the real
                // reason instead of an internal error.
                return .failure(
                    code: .readOnly,
                    message: "This card is filed as issue #\(number); edit the issue on GitHub.",
                    hint: nil
                )
            }
        } catch {
            return .failure(code: .internalError, message: error.localizedDescription, hint: nil)
        }
    }

    private func listCards(
        repo: String?, column: ElliotModel.Column?, limit: Int
    ) async throws -> ElliotResponse {
        let repos = try await store.repos()
        var repoID: UUID?
        if let repo {
            guard let match = repos.first(where: { $0.nameWithOwner == repo || $0.path == repo }) else {
                return .failure(
                    code: .repoNotFound,
                    message: "No registered repository matches \"\(repo)\".",
                    hint: "Known: \(repos.map(\.nameWithOwner).joined(separator: ", "))"
                )
            }
            repoID = match.id
        }

        let cards = try await store.cards(repoID: repoID, column: column).prefix(limit)
        var dtos: [CardDTO] = []
        for card in cards {
            dtos.append(CardDTO(
                card: card,
                repoName: repos.first { $0.id == card.repoID }?.nameWithOwner ?? "?",
                activeRunID: try await store.activeRun(cardID: card.id)?.id
            ))
        }
        return .ok(.cards(dtos))
    }

    private func getCard(_ id: UUID) async throws -> ElliotResponse {
        guard let card = try await store.card(id: id) else {
            return .failure(code: .cardNotFound, message: "No card with id \(id).", hint: nil)
        }
        let repoName = try await store.repo(id: card.repoID)?.nameWithOwner ?? "?"
        return .ok(.card(CardDTO(
            card: card,
            repoName: repoName,
            activeRunID: try await store.activeRun(cardID: id)?.id
        )))
    }

    private func createCard(
        repo: String,
        title: String,
        body: String,
        story: ElliotRequest.StoryInput?,
        column: ElliotModel.Column
    ) async throws -> ElliotResponse {
        let repos = try await store.repos()
        guard let match = repos.first(where: { $0.nameWithOwner == repo || $0.path == repo }) else {
            return .failure(
                code: .repoNotFound,
                message: "No registered repository matches \"\(repo)\".",
                hint: "Known: \(repos.map(\.nameWithOwner).joined(separator: ", "))"
            )
        }
        let card = try await board.createCard(
            repoID: match.id, title: title, body: body, story: story?.story, column: column
        )
        return .ok(.card(CardDTO(card: card, repoName: match.nameWithOwner)))
    }

    private func moveCard(
        id: UUID, to column: ElliotModel.Column, followUps: [String]
    ) async throws -> ElliotResponse {
        guard let before = try await store.card(id: id) else {
            return .failure(code: .cardNotFound, message: "No card with id \(id).", hint: nil)
        }
        let from = before.column

        // An omitted list already became `[]` at the MCP boundary: an agent
        // saying nothing about follow-ups means "none", not "ask me".
        let result = try await board.move(
            cardID: id, to: column, origin: .mcp(client: "mcp"), followUps: followUps
        )

        switch result {
        case .moved(let runID):
            let triggered: String? = runID.flatMap { _ in
                switch (from, column) {
                case (.backlog, .todo): "create-issue"
                case (.todo, .inProgress): "implement-issue"
                case (.inReview, .done): "merge-pr"
                default: nil
                }
            }
            let summary = if let triggered {
                "Moved \(from.displayName) → \(column.displayName) and started \(triggered). "
                    + "It runs in the background; poll board_list_runs to follow it."
            } else {
                "Moved \(from.displayName) → \(column.displayName). No skill runs for this transition."
            }
            return .ok(.moved(MoveDTO(
                cardID: id, from: from.rawValue, to: column.rawValue,
                runID: runID, triggered: triggered, summary: summary
            )))

        case .needsInput(.followUps):
            // Should be unreachable from MCP, since an omitted list is [].
            return .failure(
                code: .moveBlocked,
                message: "Merging needs a follow_ups list.",
                hint: "Pass follow_ups: [] for none."
            )

        case .blocked(let block):
            return .failure(
                code: .moveBlocked,
                message: Self.explain(block),
                hint: Self.hint(for: block)
            )
        }
    }

    static func explain(_ block: MoveBlock) -> String {
        switch block {
        case .sameColumn: "The card is already in that column."
        case .emptyIdea: "The card has no story, title or body to file as an issue."
        case .incompleteStory: "The story is missing one of role, want or benefit."
        case .missingIssueNumber: "The card has no issue number."
        case .missingPRNumber: "The card has no pull request number."
        case .repoDisabled: "That repository is disabled in Elliot."
        case .runAlreadyInFlight(let runID): "A run (\(runID)) is already working on this card."
        }
    }

    static func hint(for block: MoveBlock) -> String? {
        switch block {
        case .missingIssueNumber:
            "Move it backlog → todo first, which files the issue."
        case .missingPRNumber:
            "Move it todo → inProgress first, which opens the pull request."
        case .incompleteStory:
            "Set role, want and benefit on the card."
        case .runAlreadyInFlight:
            "Wait for it to finish; poll board_list_runs."
        case .repoDisabled:
            "Enable the repository in Elliot's Preflight screen."
        case .sameColumn, .emptyIdea:
            nil
        }
    }
}
