import ElliotIPC
import ElliotModel
import ElliotStore
import Foundation

/// `ElliotMCPKit`'s counterpart to `MCPRequestHandler`: the same requests, the
/// same refusals, answered from a read-only snapshot of the database.
///
/// It exists so `BridgeProviding.read` hands back an `ElliotResponse` whichever
/// way it was served. Before it, `BridgeOutcome.offline` carried a `BoardStore`
/// and every read tool had two bodies — one rendering the answer the app built,
/// one rebuilding that answer out of rows. Six sites did that, and four of them
/// had to be taught the same lesson separately: refuse a repository nobody
/// registered, refuse a card id nothing matches rather than answer an empty
/// page, fill `activeRunID` so a held card does not read as movable. Nothing in
/// the reply told an agent which branch had served it, so the second answer got
/// believed.
///
/// The two implementations cannot literally share code: `MCPRequestHandler`
/// lives in `ElliotEngine`, and this module imports neither `ElliotEngine` nor
/// `ElliotProcess` — the invariant that keeps the helper from holding a copy of
/// the rules. What they share is a vocabulary, which is enough for
/// `OfflineParityTests` to drive both from one board and compare the bytes.
///
/// Nothing here decides or phrases anything an agent could not have got from the
/// app: the candidates come from `nextCandidates`, the order from
/// `rankNextSteps`, each item from `NextDTO(step:rank:activeRunID:)` — all three
/// pure, all three shared with the app, all three below both layers.
struct OfflineResponder: Sendable {
    let store: BoardStore

    /// Exhaustive by construction — no `default`, the same bargain
    /// `MCPRequestHandler.handle` strikes and comments on. A read case added to
    /// the wire has to be answered here before the helper builds, instead of
    /// reaching an agent as a plausible refusal.
    ///
    /// The write cases are unreachable in production — `AppBridge.write` never
    /// consults a snapshot, and refuses before it gets this far — but they are
    /// spelled out rather than swept into a `default`, because a `default` is
    /// exactly what would answer a *read* case nobody had implemented yet.
    func respond(to request: ElliotRequest) async -> ElliotResponse {
        do {
            switch request {
            case .hello:
                // There is no handshake with a file. `.ok(.hello)` here would
                // have a snapshot introduce itself as the running app.
                return .failure(
                    code: .appUnavailable,
                    message: "Elliot is not running; a snapshot of its database cannot answer a handshake.",
                    hint: "Open Elliot.app."
                )
            case .listCards(let repo, let column, let limit):
                return try await listCards(repo: repo, column: column, limit: limit)
            case .getCard(let id):
                return try await getCard(id)
            case .listRuns(let cardID, let limit):
                return try await listRuns(cardID: cardID, limit: limit)
            case .listRepos:
                return .ok(.repos(try await store.repos().map { RepoDTO(repo: $0) }))
            case .next(let repo, let limit):
                return try await next(repo: repo, limit: limit)
            case .listProposals(let analysisID, let repo, let status, let limit):
                return try await listProposals(
                    analysisID: analysisID, repo: repo, status: status, limit: limit
                )
            case .createCard:
                return Self.readOnly("Creating a card")
            case .updateCard:
                return Self.readOnly("Correcting a card")
            case .moveCard:
                return Self.readOnly("Moving a card")
            case .awaitRun:
                return Self.readOnly("Waiting on a run")
            case .cancelRun:
                return Self.readOnly("Cancelling a run")
            case .analyzeRepo:
                return Self.readOnly("Analysing a repository")
            case .acceptProposals:
                return Self.readOnly("Accepting a proposal")
            case .rejectProposals:
                return Self.readOnly("Rejecting a proposal")
            case .screenshot:
                // `app_unavailable`, not `read_only`. Nothing is being written;
                // there is simply no window. Saying "read only" would send an
                // agent looking for a permission problem that does not exist,
                // and `read_only` is the code that means "come back when Elliot
                // is up *and* stop trying to write" — only half of which is true
                // here.
                return .failure(
                    code: .appUnavailable,
                    message: "Elliot is not running; a snapshot of its database has no window to "
                        + "photograph.",
                    hint: "Open Elliot.app."
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
        // One query for the whole page, as the app does it: the per-card lookup
        // this replaces was a round trip per row.
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
        return .ok(.card(try await dto(for: card)))
    }

    private func listRuns(cardID: UUID?, limit: Int) async throws -> ElliotResponse {
        // An unknown card is a refusal, not an empty page: "this card has no
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
        // Unlimited on purpose, as `BoardService.nextSteps` does it: the limit
        // cuts the *ranked* answer, and a limit applied before ranking would
        // hide the one ready card behind ten blocked ones.
        let cards = try await store.cards(repoID: repoID)
        let active = try await store.activeRuns(cardIDs: cards.map(\.id))

        let steps = rankNextSteps(
            nextCandidates(cards: cards, repos: repos, activeRunIDs: active.mapValues(\.id))
        )
        let shown = Array(steps.prefix(page.limit))
        let items = shown.indices.map { index in
            NextDTO(step: shown[index], rank: index + 1, activeRunID: active[shown[index].card.id]?.id)
        }
        return .ok(.next(NextPage(
            items: items,
            total: steps.count,
            limit: page.limit,
            readyCount: steps.filter(\.isReady).count,
            limitCappedFrom: page.cappedFrom
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
        let names = Self.names(of: repos)
        return .ok(.proposals(proposals.map { proposal in
            ProposalDTO(proposal: proposal, repoName: names[proposal.repoID] ?? "?")
        }))
    }

    // MARK: - Refusing a write

    /// `read_only` and not `app_unavailable`: the database is right here and
    /// readable, and the reason this cannot be served is that serving it would
    /// change the board without firing its rule.
    private static func readOnly(_ act: String) -> ElliotResponse {
        .failure(
            code: .readOnly,
            message: "\(act) needs the running app; this helper opened the database read-only.",
            hint: "Open Elliot.app and try again."
        )
    }

    // MARK: - Resolving

    /// A repository filter, resolved — the same three values
    /// `MCPRequestHandler` resolves to, phrased the same way.
    ///
    /// `all` and "matched nothing" are deliberately different values. Collapsing
    /// them turns a question about one repository into an answer about every
    /// repository, and the caller has no way to tell.
    enum RepoFilter {
        case all
        case one(Repo)
        case unknown(ElliotResponse)
    }

    static func filter(_ name: String?, in repos: [Repo]) -> RepoFilter {
        guard let name else { return .all }
        guard let match = repos.first(where: { $0.nameWithOwner == name || $0.path == name }) else {
            return .unknown(.failure(
                code: .repoNotFound,
                message: "No registered repository matches \"\(name)\".",
                hint: "Known: \(repos.map(\.nameWithOwner).joined(separator: ", "))"
            ))
        }
        return .one(match)
    }

    static func names(of repos: [Repo]) -> [UUID: String] {
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

    /// The snapshot's half of the reading — see `MCPRequestHandler.prStatusDTO`,
    /// which this must match word for word, and which `OfflineParityTests`
    /// proves it does.
    ///
    /// Note this half is the *more* honest of the two by circumstance: the app
    /// may have been closed for days when the helper is asked, and the age rule
    /// is what stops the snapshot reporting a week-old green.
    private func prStatusDTO(for card: Card) async throws -> PRStatusDTO? {
        // In Review only, matching what `PRWatcher` bothers to read and what the
        // app renders. Without it a card `merge-pr` has just moved to Done keeps
        // serving its **pre-merge** reading as fresh for the whole `maximumAge`
        // window — "a review is required", about a pull request already merged.
        guard card.column == .inReview, let number = card.prNumber else { return nil }

        // `try?`, and this is the one place it is right. `openReadOnly`
        // deliberately accepts a database **older** than this helper, so the
        // board is not blanked between upgrading the bundle and the next launch
        // of the app. That tolerance was written for added *columns*, which read
        // as absent; `v8_prStatus` adds a *table*, and querying a missing table
        // throws. Letting it propagate would answer `app_unavailable` to every
        // offline `board_get_card` in exactly the window `openReadOnly` exists
        // to keep working. No reading is the honest answer there.
        guard let status = try? await store.prStatus(repoID: card.repoID, prNumber: number)
        else { return nil }
        return PRStatusDTO(status, resolved: status.resolved(now: Date(), currentHeadOid: nil))
    }
}
