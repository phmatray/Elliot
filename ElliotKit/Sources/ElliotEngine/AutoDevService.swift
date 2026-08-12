import ElliotIPC
import ElliotModel
import ElliotStore
import Foundation

/// Why `AutoDevService.start` refused.
///
/// ⛔ **`.repoDisabled`/`.repoBlocked` are not two cases here** — they are
/// `UnattendedStartRefusal.repoDisabled`/`.preflightBlocked`, carried whole
/// rather than re-derived, exactly as `AnalysisError.repoRefused` carries them
/// (`AnalysisService.swift:16`). Writing two local cases that mirror the rule's
/// own would be a fifth hand-written copy of the one thing
/// `UnattendedStartRefusal` exists to stop repeating — see that type's own doc,
/// "one rule, four callers"; this service is the fifth.
public enum AutoDevError: Error, LocalizedError, Equatable {
    case repoNotFound(UUID)
    case repoRefused(UnattendedStartRefusal)
    case noCards
    case foreignCard(UUID)
    case noDailySpendCeiling

    public var errorDescription: String? {
        switch self {
        case .repoNotFound(let id): "No repository with id \(id)."
        case .repoRefused(let refusal): refusal.sentence
        case .noCards: "Pick at least one card for the session to work on."
        case .foreignCard(let id):
            "Card \(id) belongs to another repository; a session works on one repository."
        case .noDailySpendCeiling:
            "Set a daily spending ceiling before starting an unattended session."
        }
    }

    /// The wire code and the next action, shaped like the `AnalysisError`
    /// mapping written out at `MCPRequestHandler.swift:173-222`.
    ///
    /// Here rather than in a `catch` because **no request raises it yet** — PR4
    /// ships no wire case and no MCP tool — and a mapping that lives beside the
    /// error cannot drift from it while it waits for one. Nothing can put
    /// `auto_dev_refused` on the wire, so `elliotProtocolVersion` is
    /// unaffected.
    public var response: (code: ElliotErrorCode, message: String, hint: String?) {
        switch self {
        case .repoNotFound:
            return (
                .repoNotFound, errorDescription ?? "",
                "board_list_repos lists the repositories Elliot drives."
            )
        case .repoRefused(let refusal):
            // The message is the rule's sentence; only the *remedy* is decided
            // here, switched over exhaustively so a new `UnattendedStartRefusal`
            // case cannot silently inherit a hint that names the wrong screen —
            // the same discipline `MCPRequestHandler`'s `AnalysisError` mapping
            // uses for the same type.
            let hint: String
            switch refusal {
            case .repoDisabled: hint = "Enable the repository in Elliot's Preflight screen."
            case .preflightBlocked:
                hint = "Open Elliot's Preflight screen and clear the failing check."
            }
            return (.autoDevRefused, errorDescription ?? "", hint)
        case .noCards:
            return (.autoDevRefused, errorDescription ?? "", "Engage at least one Backlog card.")
        case .foreignCard:
            return (.autoDevRefused, errorDescription ?? "", "Start one session per repository.")
        case .noDailySpendCeiling:
            return (
                .autoDevRefused, errorDescription ?? "",
                "Set a daily ceiling in Preflight. A session removes the human rhythm the "
                    + "per-run brake was sized against."
            )
        }
    }
}

/// The board driving its own cards.
///
/// Advancing is **re-evaluation, not progression**: on every event the session
/// walks its unsettled cards and asks `BoardService` what the next move would
/// mean, exactly as a drag would. Nothing is remembered between rounds — there
/// is no cursor saying "this card is at step 3" — which is what makes resuming
/// after a crash trivial: there is no state to rebuild.
///
/// It spawns nothing itself. Every run it causes goes through `launcher.launch`
/// → `pump()` → `refusal(for:)`, so `SchedulerLimits`, `SpendCeiling` and the
/// repository-exclusion rules bind it exactly as they bind a drag.
///
/// ## Reentrancy
///
/// This actor calls `BoardService`, which calls `RunScheduler`, which calls back
/// here through `RoundTriggering`. Swift actors are reentrant and never block,
/// so the cycle cannot deadlock; what it can do is interleave two rounds at
/// every `await`. Three things contain that, and all three are load-bearing:
///
/// - a round is **coalesced** — a trigger arriving while one is running sets a
///   flag and returns, and the runner loops until the flag is clear, so at most
///   one round is ever in flight;
/// - a round **re-reads** its state from the store rather than carrying rows
///   across an `await`, so an interleaved write cannot be lost;
/// - the scheduler notifies **after** it has persisted the run and drained the
///   queue, so a round never observes a half-written run.
///
/// The references out are the ones that already exist in this shape:
/// `RunScheduler.systemMover` and `PRWatcher.mover` are weak for the same
/// cycle-breaking reason, and the hooks that point back here are weak too.
///
/// ⚠️ **This is the narrower, engine-facing half.** `AutoDevDriving`
/// (`AutoDevDriving.swift`) is the higher-level surface `AppModel` drives —
/// `start(repoID:selection:)`, `pause`, `resume`, `stop`, `engagements`,
/// `session(sessionID:)` — and this actor's own `start(session:preflight:)`
/// below takes an already-built `AutoDevSession` rather than a repository and a
/// selection. The conformance, in the `// MARK: - AutoDevDriving` extension at
/// the end of **this file** — not a separate `+Driving.swift`, since `store`,
/// `board`, `launcher` and `clock` above are all `private`, and Swift's
/// `private` is file-scoped — adapts one to the other: it resolves a
/// `Selection` into an engaged set (PR2's `CardRanking.rank`) and forwards to
/// this method, and adds the four calls this actor does not declare directly.
/// Obligation one from that protocol's doc is honoured here regardless of the
/// conformance, because it applies just as much to this narrower `start`: see
/// the comment at the end of the method below.
public actor AutoDevService: RoundTriggering {
    private let store: BoardStore
    private let board: BoardService
    private let launcher: any RunLaunching
    private let queue: any RunQueueReading
    /// The clock, injected — the idiom of `PRStatus.resolved(now:)`. Every
    /// patience window in a test is expressed by moving this, never by sleeping.
    private let clock: @Sendable () -> Date
    /// Whether a round is currently running. See ``advance()``.
    private var roundInFlight = false
    /// Set by a trigger that arrived while a round was already running, so the
    /// runner in ``advance()`` loops once more instead of dropping it.
    private var roundRequested = false

    public init(
        store: BoardStore,
        board: BoardService,
        launcher: any RunLaunching,
        queue: any RunQueueReading,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.board = board
        self.launcher = launcher
        self.queue = queue
        self.clock = clock
    }

    // MARK: - Starting

    /// Engages `session.engagedCardIDs` against `session.repoID` and starts
    /// driving them.
    ///
    /// - Parameter preflight: Preflight's verdict on `session.repoID`, taken by
    ///   the caller — not read here. Decision, not oversight:
    ///   `UnattendedStartRefusal.refusal`'s own doc says the parameter decides,
    ///   never `repo.preflightVerdict`, because a caller that has just swept
    ///   holds a fresher verdict than the persisted column. Reading it here
    ///   instead would also mean building a `PreflightService` — which needs a
    ///   captured login shell and would make this actor untestable in
    ///   `swift test` — or accepting a `RepoGating`, which
    ///   `PreflightGate.verdict(for:)` would then re-sweep on every call,
    ///   costing six subprocesses and a network round trip twice for a caller
    ///   that already paid for one.
    @discardableResult
    public func start(
        session: AutoDevSession, preflight: PreflightState
    ) async throws -> AutoDevSession {
        guard let repo = try await store.repo(id: session.repoID) else {
            throw AutoDevError.repoNotFound(session.repoID)
        }
        // The one rule, composed rather than hand-written a fifth time — see
        // `UnattendedStartRefusal`'s own doc and this file's `AutoDevError`
        // comment. Asked before the ceiling and the card checks below, the same
        // order `AnalysisService.start` uses, because a repository the reader
        // switched off is the answer regardless of what else is wrong with the
        // request.
        if let refusal = UnattendedStartRefusal.refusal(repo: repo, preflight: preflight) {
            throw AutoDevError.repoRefused(refusal)
        }
        // `SpendCeiling.swift:5-14` says the brake was sized against the rhythm
        // of a human dragging cards. A session removes that assumption: nothing
        // else stands between an unattended loop and the meter.
        guard (try await store.spendCeiling())?.perDayUSD != nil else {
            throw AutoDevError.noDailySpendCeiling
        }

        // Ordered-unique: naming a card twice is a slip, not a request for two
        // engagements — the same reading `AnalysisService.start` gives angles.
        var engaged: [UUID] = []
        for id in session.engagedCardIDs where !engaged.contains(id) { engaged.append(id) }
        guard !engaged.isEmpty else { throw AutoDevError.noCards }
        for id in engaged {
            guard let card = try await store.card(id: id), card.repoID == session.repoID else {
                throw AutoDevError.foreignCard(id)
            }
        }

        let now = clock()
        var opened = session
        opened.engagedCardIDs = engaged
        opened.state = .running
        opened.startedAt = now
        opened.endedAt = nil

        let rows = engaged.map {
            AutoDevEngagement(
                sessionID: opened.id, cardID: $0, attempts: 0,
                disposition: .engaged, reason: "Not started yet.", updatedAt: now)
        }
        // One transaction, the shape and the reason of
        // `saveAnalysis(_:runs:)`: a session with fewer rows than it was
        // started with is a promise that quietly shrank, and nothing walks the
        // array against the rows afterwards to notice.
        try await store.saveAutoDevSession(opened, cards: rows)

        await advance()

        // Obligation 1 from `AutoDevDriving`'s own doc, which binds this
        // method independently of the `AutoDevDriving` conformance in the
        // extension at the end of this file: "a loop that reaches its own end
        // must make that observable." `advance()` may
        // already have settled every engaged card and flipped the session to
        // `.finished` by the time it returns — for a session with exactly one
        // round of work, that happens on this very call. Returning the
        // in-memory `opened` here would report `.running` forever for that
        // case; re-reading the stored row is what makes the outcome the caller
        // sees match the row `advance()` actually wrote. The `?? opened`
        // fallback only matters if the row vanished between the write above and
        // this read, which nothing in this actor does.
        return try await store.autoDevSession(id: opened.id) ?? opened
    }

    /// Whether anything unattended is going on — what `PRWatcher` asks before it
    /// widens its own backoff.
    public func hasRunningSession() async -> Bool {
        !(((try? await store.runningAutoDevSessions()) ?? []).isEmpty)
    }

    // MARK: - RoundTriggering

    public func triggerRound() async {
        await advance()
    }

    // MARK: - Advancing

    /// One coalesced pass over every running session.
    ///
    /// Coalesced rather than queued: a round asks the board the same question
    /// again from scratch, so two rounds back to back are one round. A trigger
    /// arriving while one is in flight sets a flag and returns at once — which
    /// is also what keeps `RunScheduler.finish` from waiting on a whole round
    /// before it returns.
    public func advance() async {
        guard !roundInFlight else {
            roundRequested = true
            return
        }
        roundInFlight = true
        defer { roundInFlight = false }
        repeat {
            roundRequested = false
            await round()
        } while roundRequested
    }

    private func round() async {
        // The user's own stop outranks everything. Recording dispositions while
        // the queue is paused would burn the patience window against a hold the
        // reader put there on purpose.
        guard await queue.queueIsPaused() == false else { return }
        for session in (try? await store.runningAutoDevSessions()) ?? [] {
            await advance(session)
        }
    }

    private func advance(_ session: AutoDevSession) async {
        let now = clock()
        var states = (try? await store.autoDevEngagements(sessionID: session.id)) ?? []
        guard !states.isEmpty else {
            // A pure short-circuit, not a correctness requirement: every
            // engaged card was deleted, and `[].allSatisfy(\.isSettled)` is
            // vacuously true, so the trailing `finish` call below would reach
            // the same conclusion on its own. This only skips a handful of
            // now-pointless store reads (`card`, `activeRuns`,
            // `queueSnapshot()`) for a session already known to have nothing
            // left.
            await finish(session)
            return
        }

        // Walked in the order the person engaged them, **not** in the order the
        // rows came back. `autoDevEngagements` orders on `updatedAt`, and at the
        // start of a session every row carries the same timestamp — so the walk
        // order would be whatever SQLite happened to return, and it decides
        // which card gets the session's one merge slot below. The engaged list
        // is the promise and it is ordered; the rows are the state.
        let engagedOrder = Dictionary(
            session.engagedCardIDs.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        states.sort { (engagedOrder[$0.cardID] ?? .max) < (engagedOrder[$1.cardID] ?? .max) }

        // Three reads per session, not per card.
        var cards: [UUID: Card] = [:]
        for id in session.engagedCardIDs {
            if let card = (try? await store.card(id: id)) ?? nil { cards[id] = card }
        }
        let active = (try? await store.activeRuns(cardIDs: session.engagedCardIDs)) ?? [:]
        let held = Dictionary(
            (await queue.queueSnapshot()).compactMap { row in row.cardID.map { ($0, row.refusal) } },
            uniquingKeysWith: { first, _ in first }
        )

        // A session runs at most one merge, and **nothing beside it**.
        //
        // Stronger than "no new implement-issue", for the reason the design
        // gives: `pump()` steps over a refused run and admits the next — it
        // records `lastRefusals[runID]` and continues its loop rather than
        // stopping — so on a repository the session keeps busy
        // `.mergeWaitsForRepoToBeIdle` can otherwise never lift. Anything
        // started beside a pending merge is one more thing that merge waits for.
        //
        // `var`, and that is the whole of it: a merge this very round queued
        // holds everything after it exactly as one already in flight does.
        // Computed once before the loop and never updated, the round that
        // queues a merge also starts the next card's run — and the serialising
        // would be off by precisely the case it exists for.
        var mergePending = active.values.contains { $0.kind == .mergePR }

        var aborted: String?
        for index in states.indices {
            if aborted != nil { break }
            let state = states[index]
            guard !state.isSettled else { continue }

            guard let card = cards[state.cardID] else {
                states[index] = record(
                    state, .settle(.blocked, reason: "This card is no longer on the board."),
                    now: now)
                continue
            }

            // Settled the moment `gh` says the merge landed.
            if await didMerge(cardID: card.id) {
                states[index] = record(state, .settle(.merged, reason: "Merged."), now: now)
                continue
            }

            if let run = active[card.id] {
                let disposition: Disposition
                if let refusal = held[card.id] {
                    disposition = AutoDevPolicy.held(
                        refusal, unchangedSince: state.updatedAt,
                        patience: session.patience, now: now)
                } else {
                    disposition = AutoDevPolicy.disposition(
                        outcome: .blocked(.runAlreadyInFlight(runID: run.id)),
                        attempts: state.attempts,
                        maxAttempts: session.maxAttemptsPerCard,
                        unchangedSince: state.updatedAt, patience: session.patience, now: now)
                }
                states[index] = record(state, disposition, now: now)
                continue
            }

            if mergePending {
                states[index] = record(
                    state,
                    AutoDevPolicy.held(
                        .mergeWaitsForRepoToBeIdle, unchangedSince: state.updatedAt,
                        patience: session.patience, now: now),
                    now: now)
                continue
            }

            guard let to = card.column.naturalNext else {
                // Done, with no merged run behind it. `commitMove` puts a card
                // in Done *before* the run (`BoardService.commitMove`) and
                // `CardOutcome.applied` returns no move for `.notMerged`, so a
                // failed merge leaves it exactly here. The column separates
                // neither case; `didMerge` above already did.
                states[index] = record(
                    state,
                    .settle(.blocked, reason: card.lastError ?? "The merge did not land."),
                    now: now)
                continue
            }

            let proposal: MoveProposal
            do {
                proposal = try await board.proposeMove(
                    cardID: card.id, to: to, origin: .autoDev(sessionID: session.id),
                    // Always `[]`: the session merges, filing nothing of its
                    // own. Follow-ups genuinely found in the pull request are
                    // filed by `merge-pr` itself.
                    followUps: [],
                    requiresVerifiedGreen: true
                )
            } catch {
                states[index] = record(
                    state, .settle(.blocked, reason: error.localizedDescription), now: now)
                continue
            }

            // No `reading:` argument here: `AutoDevPolicy.disposition` decides
            // off `proposal.outcome` alone. A `.blocked(.notVerifiedGreen(reason:))`
            // already carries the `NotGreenReason` `evaluateMove` computed —
            // there is no separate `PRReading` to pass, and no second read to
            // take.
            let disposition = AutoDevPolicy.disposition(
                outcome: proposal.outcome,
                attempts: state.attempts,
                maxAttempts: session.maxAttemptsPerCard,
                unchangedSince: state.updatedAt,
                patience: session.patience,
                now: now
            )

            switch disposition {
            case .retry:
                var advanced = record(state, disposition, now: now)
                // Attempts count runs **started**, never rounds taken: a
                // `.noAction` move advances a card and spawns nothing, and
                // charging it an attempt would exhaust a session on free moves.
                if case .some(.moved(let runID)) = try? await board.commitMove(proposal),
                    runID != nil {
                    advanced.attempts += 1
                    // The merge this round just queued holds every card after
                    // it, for the same reason one already in flight does.
                    if case .action(.mergePR) = proposal.outcome { mergePending = true }
                }
                states[index] = advanced

            case .abortSession(let reason):
                aborted = reason
                states[index] = record(state, disposition, now: now)

            case .wait, .held, .settle:
                states[index] = record(state, disposition, now: now)
            }
        }

        if let aborted {
            // `repoDisabled` and `repoBlocked` end the **session**, not one
            // card: nothing else engaged here could run either.
            for index in states.indices where !states[index].isSettled {
                states[index] = record(states[index], .abortSession(reason: aborted), now: now)
            }
        }

        for state in states { try? await store.saveAutoDevEngagement(state) }

        if states.allSatisfy(\.isSettled) { await finish(session) }
    }

    /// Writes a disposition onto a card's row, moving `updatedAt` **only** when
    /// the reason changed.
    ///
    /// That is the whole patience mechanism. A timestamp refreshed on every
    /// round would make the window infinite and every stuck card immortal — the
    /// one line in this file that has to be read twice.
    private func record(
        _ state: AutoDevEngagement, _ disposition: Disposition, now: Date
    ) -> AutoDevEngagement {
        var updated = state
        updated.disposition = disposition.engagement
        if disposition.reason != state.reason {
            updated.reason = disposition.reason
            updated.updatedAt = now
        }
        return updated
    }

    /// Whether the card's newest terminal merge run actually merged.
    ///
    /// Read from the persisted row — `RunScheduler` writes `verifiedOutcome`
    /// once `Verifier` has judged the run and saves it on the way to
    /// terminal — and never from the column: `commitMove` puts the card in
    /// Done *before* the run, so Done means "a merge was attempted", not "a
    /// merge landed".
    ///
    /// `if case`, not a `switch`: this asks one question of `VerifiedOutcome`,
    /// and a fourth exhaustive switch over it is exactly what `CardOutcome`
    /// exists to prevent.
    private func didMerge(cardID: UUID) async -> Bool {
        let runs = (try? await store.runs(cardID: cardID, limit: 20)) ?? []
        guard let merge = runs.first(where: { $0.kind == .mergePR && $0.state.isTerminal })
        else { return false }
        if case .merged = merge.verifiedOutcome { return true }
        return false
    }

    /// Ends a session, and lets go of what its cards are still holding.
    ///
    /// **Abandoning a card and cancelling its run are not the same act, and
    /// only the second frees the card.** A `.stalled` run is non-terminal
    /// (`RunState.isTerminal`), so `activeRun`/`activeRuns` answer with it for
    /// ever; a `.queued` run held by a refusal such as
    /// `.mergeWaitsForRepoToBeIdle` is the same shape one refusal over. Both
    /// would otherwise outlive the session that made them, hold their card
    /// against every future move, and be waited on by nobody.
    ///
    /// ⛔ A `.running` run is deliberately left alone: patience expiry can
    /// settle a card even while its run is genuinely still going
    /// (`AutoDevPolicy`'s `.runAlreadyInFlight` arm does not consult
    /// `RunState`), so this method *is* reached with a live child in the
    /// picture. The only path that stops one is the reader's own stop —
    /// ``stop(sessionID:)``, 130 lines below in this file — not a session giving
    /// up on its own. `.cancelling` is spared for a
    /// different reason: the SIGTERM is already out
    /// (`RunState.isCancellable` excludes it too), so cancelling it again is
    /// a no-op at best.
    ///
    /// One batched read, not one per card — `advance(_:)` above states the
    /// same principle ("three reads per session, not per card") and this
    /// follows it.
    private func finish(_ session: AutoDevSession) async {
        let active = (try? await store.activeRuns(cardIDs: session.engagedCardIDs)) ?? [:]
        for run in active.values where shouldCancelOnTermination(run.state) {
            await launcher.cancel(runID: run.id)
        }

        var ended = session
        ended.state = .finished
        ended.endedAt = clock()
        try? await store.saveAutoDevSession(ended)
    }

    /// Whether ending a session should cancel a run its own card is still
    /// holding, decided per `RunState` rather than as a boolean condition.
    ///
    /// **Exhaustive, with no `default:`**, for the reason `MoveOrigin
    /// .allowsSideEffects` and `RunState.isUnderway` are — a case added to
    /// `RunState` must be classified here deliberately, rather than silently
    /// inheriting "don't cancel it" the way a boolean guard would. The five
    /// terminal cases are unreachable in practice — `activeRun`/`activeRuns`
    /// only ever return an active run — but the switch stays total over the
    /// whole enum rather than leaning on that.
    private func shouldCancelOnTermination(_ state: RunState) -> Bool {
        switch state {
        case .queued, .stalled: true
        case .running, .cancelling: false
        case .succeeded, .completedWithDenials, .failed, .cancelled, .timedOut: false
        }
    }
}

// MARK: - AutoDevDriving

extension AutoDevService: AutoDevDriving {

    /// The two defaults every unattended session opens with, until a screen
    /// exists to choose them per session or per repository. Nothing anywhere
    /// in this tree picks either value today — `AppModel.startAutoDev` only
    /// ever chooses `selection` — so one constant each is the honest answer
    /// rather than a number invented once for this file alone. `900` (fifteen
    /// minutes) is what this suite's own fixtures already converge on almost
    /// everywhere they hand-write a `patience`; `3` sits in the middle of the
    /// range (1-3) those same fixtures use for `maxAttemptsPerCard`.
    static let defaultMaxAttemptsPerCard = 3
    static let defaultPatience: TimeInterval = 900

    /// Turns a selection into a closed set of engaged cards, then starts.
    ///
    /// `.automatic` is the design's "optional automatic selection of the
    /// highest-value cards" (`AutoDevSelection`'s own doc). The ranking is
    /// PR2's pure function, `CardRanking.rank` — this actor performs the I/O,
    /// reading the repository's own Backlog, and holds the answer. A card
    /// nothing has measured is refused by that function and simply does not
    /// appear in `ranked`; it is never ranked low. `refused` is not surfaced
    /// anywhere from here — neither `AutoDevSession` nor `AutoDevEngagement`
    /// has a field for it. So `.automatic` engages *fewer* cards rather than
    /// wrong ones, silently: ask for five, get three, hear nothing. A shortfall
    /// on the one path the design calls optional automatic selection, and the
    /// field to carry it is worth adding before that path is leaned on.
    ///
    /// - Parameter preflight: unlike `start(session:preflight:)` above, this
    ///   entry point has no fresher reading to offer than the persisted
    ///   column: it holds no `PreflightService` collaborator (deliberately —
    ///   see this actor's own doc), so it reads `repo.preflightVerdict`, the
    ///   same value `AppModel.autoDevRefusal` already gates on, never
    ///   `PreflightReading.verdict(of:)` —
    ///   whose absent-reading case, `.notChecked`, *admits*, and would let an
    ///   unattended session start against a repository Preflight had already
    ///   failed.
    public func start(repoID: UUID, selection: AutoDevSelection) async throws -> AutoDevSession {
        guard let repo = try await store.repo(id: repoID) else {
            throw AutoDevError.repoNotFound(repoID)
        }
        let engaged: [UUID]
        switch selection {
        case .automatic(let limit):
            let backlog = try await store.cards(repoID: repoID, column: .backlog)
            engaged = Array(CardRanking.rank(backlog).ranked.prefix(limit).map(\.card.id))
        case .explicit(let ids):
            engaged = ids
        }
        let opened = AutoDevSession(
            repoID: repoID, engagedCardIDs: engaged,
            maxAttemptsPerCard: Self.defaultMaxAttemptsPerCard,
            patience: Self.defaultPatience,
            startedAt: clock()
        )
        return try await start(session: opened, preflight: repo.preflightVerdict)
    }

    /// Engages no further move. The run already going finishes on its own —
    /// `stop` is the one call that reaches it, not this one.
    ///
    /// Only from `.running`: pausing a session that is not currently running
    /// would either be a silent no-op (already paused) or, for a `.finished`
    /// session, resurrect a terminal state the band renders as a permanent
    /// report. `nil` there means "cannot confirm," this protocol's rule for
    /// every state this method is not willing to move from.
    public func pause(sessionID: UUID) async -> AutoDevSession? {
        await transition(sessionID: sessionID, from: [.running], to: .paused)
    }

    /// Puts the session back to `.running` and immediately asks for a round,
    /// so a resumed session does not sit idle until the next externally
    /// triggered event — a run finishing, or the PR watcher's own tick.
    public func resume(sessionID: UUID) async -> AutoDevSession? {
        guard await transition(sessionID: sessionID, from: [.paused], to: .running) != nil
        else { return nil }
        await advance()
        // Same reasoning as `start(session:preflight:)` above: `advance()` may
        // already have re-settled and finished this very session by the time
        // it returns, so the row it wrote — not the `.running` value this
        // method just set — is what the caller must see.
        return try? await store.autoDevSession(id: sessionID)
    }

    /// Ends the session **and cancels the run already going** — the one thing
    /// `finish()` above (the internal, automatic settlement) deliberately
    /// does not do, per its own doc: patience expiry can settle a card while
    /// its run is genuinely still `.running`, and only a user's own stop
    /// reaches it.
    ///
    /// ⛔ **Obligation 2.** Unlike `pause`/`resume`, this never refuses on the
    /// session's current state: a session that is already `.finished` is
    /// exactly the case obligation 2 is about, and it still has to answer
    /// with the session rather than `nil` — including cancelling whatever
    /// live run `finish()` left alone for it, which is precisely the state
    /// the previous task proved reachable. `nil` here means only "this id is
    /// not one I can find," never "there was nothing left to stop."
    ///
    /// ⚠️ **Does not settle rows still `.engaged`.** A session stopped mid
    /// flight can leave engagement rows that are neither `.merged` nor
    /// `.blocked` — the same "fewer rows than cards" shape
    /// `AutoDevBand.of`'s own doc already treats as a deliberate boundary
    /// rather than something to falsify by clamping. Composing a settlement
    /// reason for an interrupted card is a real feature; it is not what
    /// obligation 2 asks for, which is only that the *session* is answered
    /// honestly.
    public func stop(sessionID: UUID) async -> AutoDevSession? {
        guard var session = try? await store.autoDevSession(id: sessionID) else { return nil }

        let active = (try? await store.activeRuns(cardIDs: session.engagedCardIDs)) ?? [:]
        for run in active.values where run.state.isCancellable {
            await launcher.cancel(runID: run.id)
        }

        if session.state != .finished {
            session.state = .finished
            session.endedAt = clock()
            try? await store.saveAutoDevSession(session)
        }
        return session
    }

    public func engagements(sessionID: UUID) async -> [AutoDevEngagement] {
        (try? await store.autoDevEngagements(sessionID: sessionID)) ?? []
    }

    /// The session itself, exactly as persisted — obligation 1's remedy. See
    /// the protocol's own doc for why `AppModel.refreshAutoDev` needs this and
    /// not only `engagements(sessionID:)`.
    public func session(sessionID: UUID) async -> AutoDevSession? {
        try? await store.autoDevSession(id: sessionID)
    }

    /// Reads the session, checks it is in one of `allowed`, writes `to`, and
    /// persists — the shape `pause` and `resume` share. `stop` does not use
    /// this: its transition is unconditional (obligation 2), and it does one
    /// more thing neither `pause` nor `resume` may do — cancel a run.
    private func transition(
        sessionID: UUID, from allowed: Set<AutoDevSession.State>, to newState: AutoDevSession.State
    ) async -> AutoDevSession? {
        guard var session = try? await store.autoDevSession(id: sessionID),
            allowed.contains(session.state)
        else { return nil }
        session.state = newState
        try? await store.saveAutoDevSession(session)
        return session
    }
}
