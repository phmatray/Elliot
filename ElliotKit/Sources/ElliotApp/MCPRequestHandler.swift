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

    /// Exhaustive by construction — no `default`. A request case added to the
    /// protocol has to be answered here before the app will build, rather than
    /// reaching an agent as an unhelpful internal error.
    public func handle(_ request: ElliotRequest) async -> ElliotResponse {
        do {
            switch request {
            case .hello:
                return .ok(.hello(serverVersion: ElliotBuild.version))
            case .listCards(let repo, let column, let limit):
                return try await listCards(repo: repo, column: column, limit: limit)
            case .getCard(let id):
                return try await getCard(id)
            case .createCard(let repo, let title, let body, let story, let column, let key):
                return try await createCard(
                    repo: repo, title: title, body: body,
                    story: story, column: column, idempotencyKey: key
                )
            case .updateCard(let id, let title, let body, let story):
                return try await updateCard(id: id, title: title, body: body, story: story)
            case .moveCard(let id, let to, let followUps):
                return try await moveCard(id: id, to: to, followUps: followUps)
            case .listRuns(let cardID, let limit):
                return try await listRuns(cardID: cardID, limit: limit)
            case .awaitRun(let id, let timeoutSeconds):
                return try await awaitRun(id: id, timeoutSeconds: timeoutSeconds)
            case .cancelRun(let id):
                return try await cancelRun(id: id)
            case .listRepos:
                return .ok(.repos(try await store.repos().map { RepoDTO(repo: $0) }))
            case .next(let repo, let limit):
                return try await next(repo: repo, limit: limit)
            }
        } catch let error as BoardError {
            switch error {
            case .cardNotFound(let id):
                return .failure(code: .cardNotFound, message: "No card with id \(id).", hint: nil)
            case .repoNotFound(let id):
                return .failure(code: .repoNotFound, message: "No repository \(id).", hint: nil)
            case .runNotFound(let id):
                return .failure(
                    code: .runNotFound,
                    message: "No run with id \(id).",
                    hint: "board_list_runs lists the runs of a card, most recent first."
                )
            case .cardAlreadyFiled(let number):
                // Its own code, not `read_only`: an agent told "read only"
                // retries when Elliot comes up, and this refusal never clears.
                return .failure(
                    code: .cardAlreadyFiled,
                    message: "This card is filed as issue #\(number). Its text belongs to the "
                        + "issue now, and editing the card would leave the two disagreeing.",
                    hint: "Edit the issue instead: gh issue edit \(number). The card follows the "
                        + "issue, never the other way round."
                )
            }
        } catch {
            return .failure(code: .internalError, message: error.localizedDescription, hint: nil)
        }
    }

    // MARK: - Reading

    private func listCards(
        repo: String?, column: ElliotModel.Column?, limit: Int
    ) async throws -> ElliotResponse {
        let repos = try await store.repos()
        let repoID: UUID?
        switch Self.filter(repo, in: repos) {
        case .all: repoID = nil
        case .one(let match): repoID = match.id
        case .unknown(let failure): return failure
        }

        let page = ElliotPaging.clamp(
            limit, default: ElliotPaging.cardLimitDefault, max: ElliotPaging.cardLimitMax
        )
        let cards = try await store.cards(repoID: repoID, column: column, limit: page.limit)
        let total = try await store.cardCount(repoID: repoID, column: column)
        // One query for the whole page. The per-card lookup this replaces was a
        // round trip per row, and the page is now up to five hundred rows.
        let active = try await store.activeRuns(cardIDs: cards.map(\.id))
        let names = Self.names(of: repos)

        let dtos = cards.map {
            CardDTO(card: $0, repoName: names[$0.repoID] ?? "?", activeRunID: active[$0.id]?.id)
        }
        return .ok(.cards(CardPage(
            cards: dtos, total: total, limit: page.limit, limitCappedFrom: page.cappedFrom
        )))
    }

    private func getCard(_ id: UUID) async throws -> ElliotResponse {
        guard let card = try await store.card(id: id) else {
            return .failure(code: .cardNotFound, message: "No card with id \(id).", hint: nil)
        }
        let payload = try await dto(for: card)
        return .ok(.card(payload))
    }

    private func listRuns(cardID: UUID?, limit: Int) async throws -> ElliotResponse {
        // An unknown card is an error, not an empty page: "this card has no
        // runs" and "there is no such card" are different answers, and only one
        // of them means keep waiting.
        if let cardID {
            guard try await store.card(id: cardID) != nil else {
                return .failure(code: .cardNotFound, message: "No card with id \(cardID).", hint: nil)
            }
        }

        let page = ElliotPaging.clamp(
            limit, default: ElliotPaging.runLimitDefault, max: ElliotPaging.runLimitMax
        )
        let runs = try await store.runs(cardID: cardID, limit: page.limit)
        let total = try await store.runCount(cardID: cardID)
        return .ok(.runs(RunPage(
            runs: runs.map { RunDTO(run: $0) },
            total: total, limit: page.limit, limitCappedFrom: page.cappedFrom
        )))
    }

    // MARK: - Writing

    private func createCard(
        repo: String,
        title: String,
        body: String,
        story: ElliotRequest.StoryInput?,
        column: ElliotModel.Column,
        idempotencyKey: String?
    ) async throws -> ElliotResponse {
        let repos = try await store.repos()
        guard case .one(let match) = Self.filter(repo, in: repos) else {
            return Self.unknownRepo(repo, in: repos)
        }

        let created = try await board.createCard(
            repoID: match.id, title: title, body: body, story: story?.story,
            column: column, idempotencyKey: idempotencyKey
        )
        let payload = try await dto(for: created.card)
        return .ok(.created(CardCreatedDTO(card: payload, alreadyExisted: created.alreadyExisted)))
    }

    private func updateCard(
        id: UUID, title: String, body: String, story: ElliotRequest.StoryInput?
    ) async throws -> ElliotResponse {
        let card = try await board.updateCard(
            id: id, title: title, body: body, story: story?.story
        )
        let payload = try await dto(for: card)
        return .ok(.card(payload))
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
            // Read back off the run rather than re-deriving it from the two
            // columns: the run knows which skill it is, and the transition
            // table has exactly one owner.
            var triggered: String?
            if let runID, let run = try await store.run(id: runID) {
                triggered = run.kind.skillName
            }
            let pollAfter = runID.flatMap { _ in RunDTO.pollAfterSeconds(state: .queued, age: 0) }

            let summary = if let triggered {
                "Moved \(from.displayName) → \(column.displayName) and started \(triggered). "
                    + "It runs in the background: board_await_run holds until it finishes, or "
                    + "board_list_runs shows where it got to."
            } else {
                "Moved \(from.displayName) → \(column.displayName). No skill runs for this transition."
            }
            return .ok(.moved(MoveDTO(
                cardID: id, from: from.rawValue, to: column.rawValue,
                runID: runID, triggered: triggered,
                pollAfterSeconds: pollAfter, summary: summary
            )))

        case .needsInput(.followUps):
            // Should be unreachable from MCP, since an omitted list is [].
            return .failure(
                code: .moveBlocked,
                message: "Merging needs a follow_ups list.",
                hint: "Pass follow_ups: [] for none."
            )

        case .blocked(let block):
            // The same words `board_next` predicts this refusal with. The app's
            // own `AppModel.explain` stays separate on purpose: it addresses
            // whoever is looking at the board, and a hint that names an MCP tool
            // would be nonsense on a drag.
            return .failure(
                code: .moveBlocked,
                message: MoveBlockText.explain(block),
                hint: MoveBlockText.hint(block)
            )
        }
    }

    // MARK: - Runs

    private func awaitRun(id: UUID, timeoutSeconds: Int) async throws -> ElliotResponse {
        // Clamped here, with the same function the client sized its socket
        // with. Get the two out of step and the socket hangs up on an answer
        // already on its way, which the caller reads as a dead app.
        let run = try await board.awaitRun(
            id: id,
            timeoutSeconds: ElliotTimeouts.clampAwaitSeconds(timeoutSeconds),
            pollEvery: ElliotTimeouts.awaitPollInterval
        )
        return .ok(.run(RunDTO(run: run)))
    }

    private func cancelRun(id: UUID) async throws -> ElliotResponse {
        // `board.cancel` refuses a run that never existed; `cancelling` and
        // `cancelled` are both real answers and the agent can tell them apart.
        let run = try await board.cancel(runID: id)
        return .ok(.run(RunDTO(run: run)))
    }

    // MARK: - What to do next

    private func next(repo: String?, limit: Int) async throws -> ElliotResponse {
        let repos = try await store.repos()
        let repoID: UUID?
        switch Self.filter(repo, in: repos) {
        case .all: repoID = nil
        case .one(let match): repoID = match.id
        case .unknown(let failure): return failure
        }

        let page = ElliotPaging.clamp(
            limit, default: ElliotPaging.nextLimitDefault, max: ElliotPaging.nextLimitMax
        )
        let answer = try await board.nextSteps(repoID: repoID, limit: page.limit)
        let active = try await store.activeRuns(cardIDs: answer.steps.map(\.card.id))

        // Rendered by ElliotIPC, which the helper's snapshot path renders with
        // too. Written twice, the two answers to one question drifted.
        let items = answer.steps.enumerated().map { index, step in
            NextDTO(step: step, rank: index + 1, activeRunID: active[step.card.id]?.id)
        }
        return .ok(.next(NextPage(
            items: items, total: answer.total, limit: page.limit,
            readyCount: answer.readyCount, limitCappedFrom: page.cappedFrom
        )))
    }

    // MARK: - Resolving

    /// A repository filter, resolved.
    ///
    /// `all` and "matched nothing" are deliberately different values. Collapsing
    /// them turns a question about one repository into an answer about every
    /// repository, and the caller has no way to tell.
    private enum RepoFilter {
        case all
        case one(Repo)
        case unknown(ElliotResponse)
    }

    private static func filter(_ name: String?, in repos: [Repo]) -> RepoFilter {
        guard let name else { return .all }
        guard let match = repos.first(where: { $0.nameWithOwner == name || $0.path == name }) else {
            return .unknown(unknownRepo(name, in: repos))
        }
        return .one(match)
    }

    private static func unknownRepo(_ name: String, in repos: [Repo]) -> ElliotResponse {
        .failure(
            code: .repoNotFound,
            message: "No registered repository matches \"\(name)\".",
            hint: "Known: \(repos.map(\.nameWithOwner).joined(separator: ", "))"
        )
    }

    private static func names(of repos: [Repo]) -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0.nameWithOwner) })
    }

    /// One card, with its repository named and its holding run resolved.
    ///
    /// `activeRunID` is looked up rather than left nil: absent means "no run
    /// holds this card", so skipping the lookup would report every held card as
    /// movable.
    private func dto(for card: Card) async throws -> CardDTO {
        let repoName = try await store.repo(id: card.repoID)?.nameWithOwner ?? "?"
        let activeRunID = try await store.activeRun(cardID: card.id)?.id
        return CardDTO(card: card, repoName: repoName, activeRunID: activeRunID)
    }
}
