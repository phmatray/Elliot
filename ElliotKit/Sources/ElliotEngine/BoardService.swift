import ElliotModel
import ElliotStore
import Foundation

public struct MoveProposal: Sendable {
    public var card: Card
    public var from: ElliotModel.Column
    public var to: ElliotModel.Column
    public var orderIndex: Double
    public var outcome: MoveOutcome
    public var origin: MoveOrigin
}

public enum MoveResult: Sendable, Equatable {
    case moved(runID: UUID?)
    case blocked(MoveBlock)
    case needsInput(NeedsInput)
}

public enum BoardError: Error, LocalizedError {
    case cardNotFound(UUID)
    case repoNotFound(UUID)
    case cardAlreadyFiled(Int)
    case cardTracksPullRequest(Int)
    case runNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .cardNotFound(let id): "No card with id \(id)."
        case .repoNotFound(let id): "No repository with id \(id)."
        case .cardAlreadyFiled(let number):
            "This card is filed as issue #\(number); edit the issue on GitHub."
        case .cardTracksPullRequest(let number):
            "This card tracks pull request #\(number); edit it on GitHub."
        case .runNotFound(let id): "No run with id \(id)."
        }
    }
}

/// The answer to `createCard`, which may not have created anything.
public struct CreatedCard: Sendable, Hashable {
    public var card: Card
    /// True when an idempotency key matched a card that was already there.
    public var alreadyExisted: Bool

    public init(card: Card, alreadyExisted: Bool) {
        self.card = card
        self.alreadyExisted = alreadyExisted
    }
}

/// What the board is waiting for, ranked.
///
/// `total` and `readyCount` are counted over every candidate, not over `steps`
/// — a caller that asked for three rows must still be able to tell "nothing is
/// ready" from "you asked for too few".
public struct NextSteps: Sendable, Equatable {
    public var steps: [NextStep]
    public var total: Int
    public var readyCount: Int

    public init(steps: [NextStep], total: Int, readyCount: Int) {
        self.steps = steps
        self.total = total
        self.readyCount = readyCount
    }
}

/// The only thing in Elliot that changes a card's column.
///
/// A drag and an MCP `board_move_card` call reach exactly these two methods, so
/// the two paths cannot drift: there is one rule engine and one place that runs
/// it. Everything else — the UI, the MCP helper, the PR watcher — only supplies
/// an origin.
public actor BoardService: SystemMoving {
    private let store: BoardStore
    private let launcher: any RunLaunching

    public init(store: BoardStore, launcher: any RunLaunching) {
        self.store = store
        self.launcher = launcher
    }

    /// Works out what a move would mean, without changing anything.
    public func proposeMove(
        cardID: UUID,
        to column: ElliotModel.Column,
        origin: MoveOrigin,
        followUps: [String]? = nil,
        orderIndex: Double? = nil
    ) async throws -> MoveProposal {
        guard let card = try await store.card(id: cardID) else { throw BoardError.cardNotFound(cardID) }
        guard let repo = try await store.repo(id: card.repoID) else {
            throw BoardError.repoNotFound(card.repoID)
        }

        let activeRun = try await store.activeRun(cardID: cardID)
        let context = MoveContext(
            repoIsEnabled: repo.isEnabled,
            // Read off the row this method already loaded. That is the whole
            // reason the verdict is persisted rather than held on `AppModel`:
            // the funnel every move passes through gets it with no new
            // collaborator, so a drag, `board_move_card` and `board_next`
            // cannot answer differently.
            repoPreflight: repo.preflightVerdict,
            activeRunID: activeRun?.id,
            allowSideEffects: origin.allowsSideEffects,
            providedFollowUps: followUps
        )
        let outcome = evaluateMove(from: card.column, to: column, card: card, context: context)
        let index: Double
        if let orderIndex {
            index = orderIndex
        } else {
            index = try await store.nextOrderIndex(repoID: card.repoID, column: column)
        }

        return MoveProposal(
            card: card, from: card.column, to: column,
            orderIndex: index, outcome: outcome, origin: origin
        )
    }

    /// Applies a proposal. Blocked and input-needing proposals are returned
    /// unchanged rather than forced through.
    @discardableResult
    public func commitMove(_ proposal: MoveProposal) async throws -> MoveResult {
        switch proposal.outcome {
        case .blocked(let block):
            return .blocked(block)

        case .needsInput(let need):
            return .needsInput(need)

        case .noAction:
            try await store.commitMove(
                card: proposal.card, to: proposal.to, orderIndex: proposal.orderIndex,
                origin: proposal.origin, run: nil
            )
            return .moved(runID: nil)

        case .action(let action):
            let run = try await makeRun(for: action, card: proposal.card)
            // One transaction for the card, the run and the audit. The
            // scheduler is handed the id only after it commits, so a crash in
            // between leaves a queued run for the launch sweep rather than a
            // card that moved with nothing behind it.
            try await store.commitMove(
                card: proposal.card, to: proposal.to, orderIndex: proposal.orderIndex,
                origin: proposal.origin, run: run
            )
            await launcher.launch(runID: run.id)
            return .moved(runID: run.id)
        }
    }

    /// Propose and commit in one step — what the MCP tool and simple drags use.
    @discardableResult
    public func move(
        cardID: UUID,
        to column: ElliotModel.Column,
        origin: MoveOrigin,
        followUps: [String]? = nil,
        orderIndex: Double? = nil
    ) async throws -> MoveResult {
        let proposal = try await proposeMove(
            cardID: cardID, to: column, origin: origin,
            followUps: followUps, orderIndex: orderIndex
        )
        return try await commitMove(proposal)
    }

    private func makeRun(for action: TriggerAction, card: Card) async throws -> SkillRun {
        guard let repo = try await store.repo(id: card.repoID) else {
            throw BoardError.repoNotFound(card.repoID)
        }
        let runID = UUID()
        return SkillRun(
            id: runID,
            cardID: card.id,
            repoID: card.repoID,
            kind: action.kind,
            prompt: SlashCommandBuilder.prompt(for: action),
            cwd: repo.path,
            logPath: StoreLocation.runLogURL(runID: runID).path,
            stderrPath: StoreLocation.runStderrURL(runID: runID).path,
            createdAt: Date()
        )
    }

    // MARK: - Cards

    /// Files a new card, or hands back the one an earlier attempt already filed.
    ///
    /// `idempotencyKey` is the caller's own token for "this request", and it is
    /// persisted with the card behind a unique index rather than remembered in
    /// memory. A write that reaches Elliot can spend twenty seconds launching
    /// the app before it spends thirty on the socket, so the retry of a request
    /// that timed out on the way back may well arrive at a *different* app
    /// process than the first one: an in-memory table would never see it.
    ///
    /// A key that names a card in another repository still returns that card.
    /// The index is unique board-wide, so writing a second one is not an option
    /// on the table — and the answer carries the card, so the caller can see
    /// where its key landed.
    public func createCard(
        repoID: UUID,
        title: String,
        body: String = "",
        story: UserStory? = nil,
        column: ElliotModel.Column = .backlog,
        /// The analysis lens that found this card, when one did. Defaulted, so
        /// every caller that makes a card the board asked for — the New-story
        /// sheet, `board_create_card`, the GitHub import — keeps saying nothing
        /// rather than having to say "no lens" out loud.
        angle: AnalysisAngle? = nil,
        /// The labels this card asks its issue to carry. Defaulted to none, so
        /// the common path — the New-story sheet with nothing ticked,
        /// `board_create_card`, the GitHub import — is unchanged.
        labels: [String] = [],
        idempotencyKey: String? = nil
    ) async throws -> CreatedCard {
        guard try await store.repo(id: repoID) != nil else { throw BoardError.repoNotFound(repoID) }
        // Normalised once, here, so the lookup's idea of "no key" and the
        // column's are the same value. They were not: the lookup skipped `""`
        // and the column stored it, and since the unique index counts `""` as a
        // value rather than a NULL, the first empty-keyed card poisoned every
        // later create board-wide — a permanent outage of the tool, from an
        // argument a client emits by templating an optional field.
        let key = idempotencyKey.flatMap { $0.isEmpty ? nil : $0 }
        if let existing = try await existingCard(forKey: key) {
            return CreatedCard(card: existing, alreadyExisted: true)
        }

        let now = Date()
        let card = Card(
            repoID: repoID,
            title: title,
            body: body,
            story: story,
            angle: angle,
            labels: labels,
            column: column,
            orderIndex: try await store.nextOrderIndex(repoID: repoID, column: column),
            columnEnteredAt: now,
            createdAt: now,
            updatedAt: now,
            idempotencyKey: key
        )
        do {
            try await store.saveCard(card)
        } catch {
            // Two retries of the same request, in flight at once: the unique
            // index is what actually makes "once" true, and the lookup above
            // only spares the round trip in the common case.
            if let existing = try await existingCard(forKey: key) {
                return CreatedCard(card: existing, alreadyExisted: true)
            }
            throw error
        }
        return CreatedCard(card: card, alreadyExisted: false)
    }

    /// Creates a card for something that already exists on GitHub.
    ///
    /// Deliberately not an argument on `createCard`: that one answers to the
    /// user's New-story sheet and to `board_create_card`, and always starts in
    /// Backlog with nothing filed. This one sets the column and the issue/PR
    /// numbers in the **same write**, so a crash cannot leave a card the next
    /// refresh would fail to recognise and would therefore duplicate.
    ///
    /// Still `BoardService`, so "the only thing that sets a card's column"
    /// holds. It runs no rule because there is no *move*: the card did not
    /// exist a moment ago.
    @discardableResult
    public func adoptCard(_ seed: CardSeed) async throws -> Card {
        guard try await store.repo(id: seed.repoID) != nil else {
            throw BoardError.repoNotFound(seed.repoID)
        }
        let now = Date()
        let card = Card(
            repoID: seed.repoID,
            title: seed.title,
            body: seed.body,
            story: nil,
            column: seed.column,
            orderIndex: try await store.nextOrderIndex(repoID: seed.repoID, column: seed.column),
            issueNumber: seed.issueNumber,
            issueURL: seed.issueURL,
            prNumber: seed.prNumber,
            prURL: seed.prURL,
            branch: seed.branch,
            columnEnteredAt: now,
            createdAt: seed.createdAt,
            updatedAt: now)
        try await store.saveCard(card)
        return card
    }

    /// A nil key means "no deduplication" — not "look for a card with no key".
    private func existingCard(forKey key: String?) async throws -> Card? {
        guard let key else { return nil }
        return try await store.card(idempotencyKey: key)
    }

    /// Corrects what the *user* wrote on a card: its label, its story, its note,
    /// and the GitHub labels it asks for.
    ///
    /// Deliberately not `(_ card: Card)`. The stored card is re-fetched and only
    /// these fields are overwritten, so column, order, issue, PR and
    /// branch keep their one real owner — a whole-`Card` write would be a second
    /// path that can move a card without firing a rule.
    ///
    /// ⚠️ `labels` is **optional, and `nil` means "the caller said nothing"** —
    /// not "no labels". One caller genuinely says nothing: `board_update_card`
    /// is a wire case older than this field and names only title, body and
    /// story. Were this a plain `[String]`, that path would have to pass `[]`,
    /// and every agent edit of a card's title would silently strip the labels a
    /// human chose. Same shape, and the same reason, as
    /// `MoveContext.providedFollowUps`.
    ///
    /// Refused once the card carries an issue number: from that point the issue
    /// on github.com is the record, and a card edit would silently diverge from it.
    ///
    /// Returns the corrected card so a caller over the wire can render what it
    /// now says without a second round trip. `@discardableResult` because the
    /// sheet that calls this is looking at the card already.
    @discardableResult
    public func updateCard(
        id: UUID, title: String, body: String, story: UserStory?, labels: [String]? = nil
    ) async throws -> Card {
        guard var card = try await store.card(id: id) else { throw BoardError.cardNotFound(id) }
        if let issue = card.issueNumber { throw BoardError.cardAlreadyFiled(issue) }
        // Once the card points at something on github.com, that is the record.
        // The pull-request half matters now that a card can be imported from a
        // pull request which closes no issue.
        if let pr = card.prNumber { throw BoardError.cardTracksPullRequest(pr) }
        card.title = title
        card.body = body
        card.story = story
        if let labels { card.labels = labels }
        try await store.saveCard(card)
        return card
    }

    /// Deleting a card that carries an issue or a pull request also **dismisses**
    /// it, so the next refresh does not put it straight back. Nothing on GitHub
    /// is touched: the issue stays exactly as it was, Elliot simply stops
    /// showing it. Undone by `clearDismissals`.
    public func deleteCard(id: UUID) async throws {
        if let card = try await store.card(id: id) {
            if let number = card.issueNumber {
                try? await store.dismiss(ExternalRef(kind: .issue, number: number), repoID: card.repoID)
            }
            if let number = card.prNumber {
                try? await store.dismiss(
                    ExternalRef(kind: .pullRequest, number: number), repoID: card.repoID)
            }
        }
        try await store.deleteCard(id: id)
    }

    /// Reorders a card inside its own column without going near the rule engine
    /// — an inert move by construction.
    ///
    /// The index comes from `CardReorder.index`, which is also what decides the
    /// neighbours in the first place. It used to be the same `switch` written
    /// out here: two copies of one rule, and the placement's promise and the
    /// write were free to drift apart without either side failing.
    public func reorder(cardID: UUID, between previous: Double?, and next: Double?) async throws {
        guard var card = try await store.card(id: cardID) else { throw BoardError.cardNotFound(cardID) }
        card.orderIndex = CardReorder.index(previous: previous, next: next)
        try await store.saveCard(card)
    }

    /// Stops a run the caller is looking at. The UI's path: the run is on
    /// screen, so whether it exists is not a question worth asking.
    public func cancelRun(id: UUID) async {
        await launcher.cancel(runID: id)
    }

    /// Stops a run and answers with what it became — `cancelling` while the
    /// process winds down, `cancelled` once it is gone.
    ///
    /// The path for a caller that named the run from memory. `cancelRun(id:)`
    /// cannot say whether anything was there, and silence reads as success: an
    /// agent that cancels a run id it invented would be told it worked. The
    /// check belongs here rather than in the caller, so every caller gets it.
    ///
    /// Cancelling a run that already finished is not an error. It returns the
    /// run, terminal, having done nothing — which is what the caller wanted.
    @discardableResult
    public func cancel(runID: UUID) async throws -> SkillRun {
        guard let run = try await store.run(id: runID) else { throw BoardError.runNotFound(runID) }
        guard run.state.isActive else { return run }
        await launcher.cancel(runID: runID)
        return (try await store.run(id: runID)) ?? run
    }

    /// Holds until the run reaches a terminal state or the window closes, then
    /// answers with the run either way.
    ///
    /// A timeout is not an error: the run is still going, `isTerminal` says so,
    /// `pollAfterSeconds` says when to ask again, and the caller asks again.
    /// Returning an error here would make "still working" indistinguishable
    /// from "the app died", which is the thing this method exists to fix.
    ///
    /// `nonisolated` on purpose. The wait is minutes long and the actor it
    /// belongs to is the one a drag goes through; every sleep and every re-read
    /// happens off the actor's executor, so a five-minute await cannot delay a
    /// card the user is dragging. Nothing here touches the actor's mutable
    /// state — `store` is an immutable `Sendable` let, which is what makes this
    /// legal rather than merely convenient.
    ///
    /// Polling rather than observing the database. The waiting side is one
    /// indexed row read every half second — at the 300-second ceiling, 600
    /// primary-key lookups against a local SQLite file — where an observation
    /// would buy a fraction of a second of latency for a task group, a
    /// cancellation path and a dependence on `ValueObservation` firing in a
    /// process that may have opened the store read-only.
    public nonisolated func awaitRun(
        id: UUID,
        timeoutSeconds: Int,
        pollEvery interval: TimeInterval = 0.5
    ) async throws -> SkillRun {
        guard var run = try await store.run(id: id) else { throw BoardError.runNotFound(id) }
        guard !run.state.isTerminal else { return run }

        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            try await Task.sleep(for: .seconds(interval))
            // A run that vanished mid-wait — only possible if its card was
            // deleted — reports the last state we actually saw rather than an
            // error the caller cannot act on.
            guard let latest = try await store.run(id: id) else { return run }
            run = latest
            if run.state.isTerminal { return run }
        }
        return run
    }

    // MARK: - What to do next

    /// What the board is waiting for, ranked, with the reason for everything
    /// that is not ready.
    ///
    /// Every step is decided by `rankNextSteps`, which decides by calling the
    /// same `evaluateMove` a real move calls — so this predicts what
    /// `board_move_card` would do rather than describing it a second time.
    ///
    /// Candidates are evaluated with `providedFollowUps: []`, not `nil`. That
    /// is load-bearing: `nil` means "not collected yet" and would report every
    /// in-review card as needing input, when the move an agent can actually
    /// make — merge with no follow-ups — is available to it right now. Reading
    /// a ready `inReview → done` therefore means "this will merge, filing
    /// nothing after it".
    public func nextSteps(repoID: UUID?, limit: Int) async throws -> NextSteps {
        let repos = try await store.repos()
        // Unlimited on purpose: the limit cuts the *ranked* answer, and a limit
        // applied before ranking would hide the one ready card behind ten
        // blocked ones.
        let cards = try await store.cards(repoID: repoID)
        let active = try await store.activeRuns(cardIDs: cards.map(\.id))

        // Assembled by ElliotModel, not here: the helper answers the same
        // question from a snapshot, and the two must not disagree about what
        // counts as a candidate.
        let candidates = nextCandidates(
            cards: cards,
            repos: repos,
            activeRunIDs: active.mapValues(\.id)
        )

        // `rankNextSteps` drops the cards with nowhere to go, so its count — not
        // the card count — is the number of candidates.
        let ranked = rankNextSteps(candidates)
        return NextSteps(
            steps: limit > 0 ? Array(ranked.prefix(limit)) : ranked,
            total: ranked.count,
            readyCount: ranked.filter(\.isReady).count
        )
    }

    // MARK: - SystemMoving

    /// A move Elliot decided on its own — a PR going ready, a merge noticed on
    /// github.com, the launch sweep. The rule engine maps these to `.noAction`,
    /// so nothing is triggered by them.
    public func applySystemMove(
        cardID: UUID,
        to column: ElliotModel.Column,
        reason: MoveOrigin.SystemReason
    ) async {
        guard let proposal = try? await proposeMove(
            cardID: cardID, to: column, origin: .system(reason: reason)
        ) else { return }
        _ = try? await commitMove(proposal)
    }
}
