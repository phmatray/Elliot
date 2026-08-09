import ElliotIPC
import ElliotModel
import ElliotStore
import Foundation

/// Turns an IPC request into the same board and analysis calls a drag, or the
/// analysis window, would make.
///
/// Nothing here decides anything: it resolves ids, calls `BoardService` or
/// `AnalysisService`, and translates the answer back. The rules live in one
/// place and this is not it.
public struct MCPRequestHandler: Sendable {
    private let store: BoardStore
    private let board: BoardService
    private let analysis: AnalysisService
    /// How this build photographs its own windows, if it can at all.
    ///
    /// Optional and defaulted to `nil` because the app is the only thing that
    /// has windows: every headless construction of this handler — the tests, the
    /// parity harness — genuinely has none, and a handler that manufactured one
    /// would report a picture of nothing as a picture.
    private let capture: (any WindowCapturing)?
    /// The one reader of a pull request's stored verdict, shared with
    /// `BoardService` so a page of cards and the merge that follows it read one
    /// `gh pr list` between them rather than one each.
    private let verdicts: PRVerdictReader

    public init(
        store: BoardStore,
        board: BoardService,
        analysis: AnalysisService,
        capture: (any WindowCapturing)? = nil,
        verdicts: PRVerdictReader? = nil
    ) {
        self.store = store
        self.board = board
        self.analysis = analysis
        self.capture = capture
        // A handler built without one gets a reader that cannot reach `gh`.
        // That is honest rather than lossy: every read here uses `.ageAlone`,
        // which never asks `gh` anything.
        self.verdicts = verdicts ?? PRVerdictReader(store: store, gh: nil)
    }

    /// Exhaustive by construction — no `default`. A request case added to the
    /// protocol has to be answered here before the app will build, rather than
    /// reaching an agent as an unhelpful internal error.
    /// `client` is the name the connection gave in `hello`, forwarded by
    /// `IPCServer` so an MCP move records *which* agent made it rather than the
    /// literal "mcp" (#101). Defaulted, so a caller that has no connection to
    /// name — the tests, and any future in-process dispatch — still records an
    /// MCP origin rather than being forced to invent one.
    public func handle(
        _ request: ElliotRequest, client: String = "mcp"
    ) async -> ElliotResponse {
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
                return try await moveCard(id: id, to: to, followUps: followUps, client: client)
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
            case .analyzeRepo(let repo, let angles, let maxStories, let instructions):
                return try await analyze(
                    repo: repo, angles: angles, maxStories: maxStories,
                    instructions: instructions, client: client
                )
            case .listProposals(let analysisID, let repo, let status, let limit):
                return try await listProposals(
                    analysisID: analysisID, repo: repo, status: status, limit: limit
                )
            case .acceptProposals(let ids):
                return try await decide(ids: ids, accept: true)
            case .rejectProposals(let ids):
                return try await decide(ids: ids, accept: false)
            case .screenshot(let window, let maxInlineBytes):
                return await screenshot(window: window, maxInlineBytes: maxInlineBytes)
            }
        } catch let error as BoardError {
            switch error {
            case .cardNotFound(let id):
                return .failure(
                    code: .cardNotFound,
                    message: "No card with id \(id).",
                    hint: RefusalHint.cardNotFound
                )
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
            case .cardTracksPullRequest(let number):
                // Deliberately the same wire code as `cardAlreadyFiled` rather
                // than a new one. From the agent's side the two refusals are one
                // fact — this card is pinned to something on github.com, and
                // retrying will never clear it — and a new code string would be
                // a wire change an older helper could not decode, for no gain.
                return .failure(
                    code: .cardAlreadyFiled,
                    message: "This card tracks pull request #\(number). Its text belongs to the "
                        + "pull request now, and editing the card would leave the two disagreeing.",
                    hint: "Edit the pull request instead: gh pr edit \(number). The card follows "
                        + "the pull request, never the other way round."
                )
            }
        } catch let error as AnalysisError {
            switch error {
            case .repoNotFound(let id):
                return .failure(code: .repoNotFound, message: "No repository \(id).", hint: nil)
            case .analysisNotFound(let id):
                return .failure(code: .analysisNotFound, message: "No analysis \(id).", hint: nil)
            case .noAngles:
                return .failure(
                    code: .analysisRefused,
                    message: error.localizedDescription,
                    hint: "Pick from: \(AnalysisAngle.allCases.map(\.rawValue).joined(separator: ", "))."
                )
            case .repoDisabled:
                return .failure(
                    code: .analysisRefused,
                    message: error.localizedDescription,
                    hint: "Enable the repository in Elliot's Preflight screen."
                )
            case .angleAlreadyRunning:
                return .failure(
                    code: .analysisRefused,
                    message: error.localizedDescription,
                    hint: "Poll board_list_runs and try again when it finishes."
                )
            }
        } catch {
            return .failure(code: .internalError, message: error.localizedDescription, hint: nil)
        }
    }

    // MARK: - Looking

    /// Routes a screenshot and translates its failure. Decides nothing about the
    /// picture: a successful capture is passed through byte for byte, because
    /// what the window looked like is the capturer's finding and not this
    /// layer's to edit.
    private func screenshot(window: String, maxInlineBytes: Int) async -> ElliotResponse {
        guard let capture else {
            // Not "no windows are open" — that would be a claim about the user's
            // screen, made by a build that has no way to look at it. The same
            // distinction `AnalysisReportDTO.workingTreeChanged` draws between
            // "checked, and nothing moved" and "nobody checked".
            return .failure(
                code: .internalError,
                message: "This build of Elliot cannot photograph its own windows.",
                hint: "Screenshots need the app; this handler was built without a window capturer."
            )
        }
        switch await capture.capture(window: window, maxInlineBytes: maxInlineBytes) {
        case .success(let shot):
            return .ok(.screenshot(shot))
        case .failure(let failure):
            return failure.response(for: window)
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
            return .failure(
                code: .cardNotFound,
                message: "No card with id \(id).",
                hint: RefusalHint.cardNotFound
            )
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
                return .failure(
                    code: .cardNotFound,
                    message: "No card with id \(cardID).",
                    hint: RefusalHint.cardNotFound
                )
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
        id: UUID, to column: ElliotModel.Column, followUps: [String], client: String
    ) async throws -> ElliotResponse {
        guard let before = try await store.card(id: id) else {
            return .failure(
                code: .cardNotFound,
                message: "No card with id \(id).",
                hint: RefusalHint.cardNotFound
            )
        }
        let from = before.column

        // An omitted list already became `[]` at the MCP boundary: an agent
        // saying nothing about follow-ups means "none", not "ask me".
        let result = try await board.move(
            cardID: id, to: column, origin: .mcp(client: client), followUps: followUps
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

    // MARK: - Analysis

    private func analyze(
        repo: String, angles: [String], maxStories: Int, instructions: String,
        client: String
    ) async throws -> ElliotResponse {
        let repos = try await store.repos()
        guard case .one(let match) = Self.filter(repo, in: repos) else {
            return Self.unknownRepo(repo, in: repos)
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
            origin: .mcp(client: client)
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
        let repoID: UUID?
        switch Self.filter(repo, in: repos) {
        case .all: repoID = nil
        case .one(let match): repoID = match.id
        case .unknown(let failure): return failure
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

    /// Ids are checked one at a time with a plain sequential loop, not a task
    /// group: the store call is cheap and the id lists here are short, so the
    /// concurrency would buy nothing but a harder-to-read method.
    private func decide(ids: [UUID], accept: Bool) async throws -> ElliotResponse {
        guard accept else { return try await rejectProposals(ids: ids) }
        return try await acceptProposals(ids: ids)
    }

    /// `AnalysisService.reject` discards each id's atomic claim result
    /// internally — it always marks the proposal `.rejected` when it can, but
    /// never says whether *this* call is the one that won the claim, or
    /// whether it was already `.rejected` from an earlier call, or lost to a
    /// concurrent `accept`. So `decided` here means only "named a proposal
    /// that exists," not "this call rejected it" — the summary says so
    /// explicitly rather than let `decided` overclaim on its own.
    private func rejectProposals(ids: [UUID]) async throws -> ElliotResponse {
        var known: Set<UUID> = []
        for id in ids where try await store.proposal(id: id) != nil {
            known.insert(id)
        }
        try await analysis.reject(proposalIDs: ids)
        return .ok(.proposalsDecided(DecisionDTO(
            decided: ids.filter(known.contains),
            skipped: ids.filter { !known.contains($0) },
            cards: [],
            summary: "Asked to reject \(known.count) proposal(s) that exist. A proposal a "
                + "concurrent request already decided may not have moved; they stay on the "
                + "analysis, marked, either way."
        )))
    }

    /// `AnalysisService.accept` hands back the cards it actually created,
    /// each with a freshly generated id no other caller could also be
    /// holding — so, unlike `reject`, there is proof to check an id against:
    /// it is truly decided *by this call* only when the proposal's
    /// `acceptedCardID` now points at one of the cards this call got back.
    /// An id that lost the claim race to a concurrent accept still ends up
    /// `.accepted` with a card somewhere, just not one of these — it belongs
    /// in `skipped`, not `decided`, or the two fields would disagree with
    /// each other about what this response actually contains.
    private func acceptProposals(ids: [UUID]) async throws -> ElliotResponse {
        let cards = try await analysis.accept(proposalIDs: ids)
        let cardIDs = Set(cards.map(\.id))

        var decided: [UUID] = []
        var skipped: [UUID] = []
        for id in ids {
            if let proposal = try await store.proposal(id: id),
                let acceptedCardID = proposal.acceptedCardID,
                cardIDs.contains(acceptedCardID) {
                decided.append(id)
            } else {
                skipped.append(id)
            }
        }

        let repos = try await store.repos()
        let dtos = cards.map { card in
            CardDTO(card: card, repoName: repos.first { $0.id == card.repoID }?.nameWithOwner ?? "?")
        }
        return .ok(.proposalsDecided(DecisionDTO(
            decided: decided, skipped: skipped, cards: dtos,
            summary: "Created \(cards.count) Backlog card(s). Nothing was filed on GitHub — "
                + "moving a card from backlog to todo is what does that."
        )))
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

    /// Deliberately a one-line delegation rather than the words themselves: the
    /// offline responder answers the same question and must answer it in the
    /// same bytes, and the two targets cannot import each other. See
    /// ``ElliotIPC/ElliotResponse/repoNotFound(name:in:)`` (#219).
    private static func unknownRepo(_ name: String, in repos: [Repo]) -> ElliotResponse {
        .repoNotFound(name: name, in: repos)
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
        return CardDTO(
            card: card, repoName: repoName, activeRunID: activeRunID,
            prStatus: try await prStatusDTO(for: card))
    }

    /// The stored reading, resolved against the clock.
    ///
    /// `.ageAlone`, on purpose: establishing the pull request's head right now
    /// would mean a `gh pr list` per card inside a read, and `PRWatcher` already
    /// re-reads whenever the head moves. What remains in force is the age rule,
    /// which is the one that matters when nothing has been running — the app
    /// closed, asleep, or unable to reach `gh`.
    ///
    /// `OfflineResponder` computes the identical answer, and still cannot share
    /// this code: `ElliotMCPKit` imports neither this target nor `ElliotProcess`,
    /// so the helper holds no copy of the rules. `OfflineParityTests` is what
    /// keeps them equal, and `.ageAlone` is what keeps them *able* to be equal —
    /// a snapshot can never establish a head, so a live answer that did would
    /// diverge from it by construction.
    private func prStatusDTO(for card: Card) async throws -> PRStatusDTO? {
        // In Review only — the same gate the watcher and the board apply. A card
        // `merge-pr` has just moved to Done would otherwise serve its pre-merge
        // reading as fresh for the whole `maximumAge` window, and the app and
        // this surface would disagree about the same card.
        guard card.column == .inReview, let number = card.prNumber else { return nil }
        guard let repo = try await store.repo(id: card.repoID) else { return nil }
        guard let reading = try await verdicts.reading(
            repo: repo, prNumber: number, now: Date(), head: .ageAlone)
        else { return nil }
        return PRStatusDTO(reading.status, resolved: reading.resolved)
    }
}
