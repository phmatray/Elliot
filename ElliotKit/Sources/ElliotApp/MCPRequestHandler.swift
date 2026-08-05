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
    private let analysis: AnalysisService

    public init(store: BoardStore, board: BoardService, analysis: AnalysisService) {
        self.store = store
        self.board = board
        self.analysis = analysis
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
            case .analyzeRepo(let repo, let angles, let maxStories, let instructions):
                return try await analyze(
                    repo: repo, angles: angles, maxStories: maxStories, instructions: instructions
                )
            case .listProposals(let analysisID, let repo, let status, let limit):
                return try await listProposals(
                    analysisID: analysisID, repo: repo, status: status, limit: limit
                )
            case .acceptProposals(let ids):
                return try await decide(ids: ids, accept: true)
            case .rejectProposals(let ids):
                return try await decide(ids: ids, accept: false)
            }
        } catch let error as BoardError {
            switch error {
            case .cardNotFound(let id):
                return .failure(code: .cardNotFound, message: "No card with id \(id).", hint: nil)
            case .repoNotFound(let id):
                return .failure(code: .repoNotFound, message: "No repository \(id).", hint: nil)
            }
        } catch let error as AnalysisError {
            switch error {
            case .repoNotFound(let id):
                return .failure(code: .repoNotFound, message: "No repository \(id).", hint: nil)
            case .analysisNotFound(let id):
                return .failure(code: .analysisNotFound, message: "No analysis \(id).", hint: nil)
            case .noAngles, .repoDisabled, .angleAlreadyRunning:
                return .failure(
                    code: .analysisRefused,
                    message: error.localizedDescription,
                    hint: error == .noAngles
                        ? "Pick from: \(AnalysisAngle.allCases.map(\.rawValue).joined(separator: ", "))."
                        : "Poll board_list_runs and try again when it finishes."
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

    private func analyze(
        repo: String, angles: [String], maxStories: Int, instructions: String
    ) async throws -> ElliotResponse {
        let repos = try await store.repos()
        guard let match = repos.first(where: { $0.nameWithOwner == repo || $0.path == repo }) else {
            return .failure(
                code: .repoNotFound,
                message: "No registered repository matches \"\(repo)\".",
                hint: "Known: \(repos.map(\.nameWithOwner).joined(separator: ", "))"
            )
        }
        // An unknown angle is worth its own message: a decoding failure would
        // lose the whole request and say nothing useful about why.
        var resolved: [AnalysisAngle] = []
        for raw in angles {
            guard let angle = AnalysisAngle(rawValue: raw) else {
                return .failure(
                    code: .unknownAngle,
                    message: "\"\(raw)\" is not an angle.",
                    hint: "One of: \(AnalysisAngle.allCases.map(\.rawValue).joined(separator: ", "))."
                )
            }
            resolved.append(angle)
        }

        let started = try await analysis.start(
            repoID: match.id,
            angles: resolved,
            extraInstructions: instructions,
            maxStoriesPerAngle: max(1, min(maxStories, 30)),
            origin: .mcp(client: "mcp")
        )
        return .ok(.analysisStarted(AnalysisDTO(
            analysis: started.analysis,
            repoName: match.nameWithOwner,
            runs: started.runs.map {
                AnalysisRunDTO(
                    runID: $0.id,
                    angle: $0.analysisAngle?.rawValue ?? "",
                    state: $0.state.rawValue
                )
            }
        )))
    }

    private func listProposals(
        analysisID: UUID?, repo: String?, status: String?, limit: Int
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
        let proposals = try await store.proposals(
            analysisID: analysisID,
            repoID: repoID,
            status: status.flatMap(ProposalStatus.init(rawValue:)),
            limit: limit
        )
        return .ok(.proposals(proposals.map { proposal in
            ProposalDTO(
                proposal: proposal,
                repoName: repos.first { $0.id == proposal.repoID }?.nameWithOwner ?? "?"
            )
        }))
    }

    /// Which ids exist is settled with a plain sequential loop, not a task
    /// group: the store call is cheap and the id lists here are short, so the
    /// concurrency would buy nothing but a harder-to-read method.
    private func decide(ids: [UUID], accept: Bool) async throws -> ElliotResponse {
        var known: Set<UUID> = []
        for id in ids where try await store.proposal(id: id) != nil {
            known.insert(id)
        }
        let skipped = ids.filter { !known.contains($0) }

        guard accept else {
            try await analysis.reject(proposalIDs: ids)
            return .ok(.proposalsDecided(DecisionDTO(
                decided: ids.filter(known.contains), skipped: skipped, cards: [],
                summary: "Rejected \(known.count) proposal(s). They stay on the analysis, marked."
            )))
        }

        let cards = try await analysis.accept(proposalIDs: ids)
        let repos = try await store.repos()
        let dtos = cards.map { card in
            CardDTO(card: card, repoName: repos.first { $0.id == card.repoID }?.nameWithOwner ?? "?")
        }
        return .ok(.proposalsDecided(DecisionDTO(
            decided: ids.filter(known.contains), skipped: skipped, cards: dtos,
            summary: "Created \(cards.count) Backlog card(s). Nothing was filed on GitHub — "
                + "moving a card from backlog to todo is what does that."
        )))
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
