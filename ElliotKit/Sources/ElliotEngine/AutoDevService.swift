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
/// ⚠️ **This does not conform to `AutoDevDriving`.** That protocol
/// (`AutoDevDriving.swift`) is the higher-level surface `AppModel` drives —
/// `start(repoID:selection:)`, `pause`, `resume`, `stop`, `engagements` — and
/// its own doc names two obligations on whichever type adopts it: a finished
/// session must become observable, and `stop` must never answer `nil` for a
/// session that was already finished. This actor's `start(session:preflight:)`
/// takes an already-built `AutoDevSession` rather than a repository and a
/// selection, and declares neither `pause`, `resume`, `stop` nor `engagements`
/// — those, and the `AutoDevDriving` conformance itself, belong to whichever
/// later task adapts this service into that surface. Obligation one is honoured
/// here anyway, because it applies just as much to this narrower `start`: see
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

        // Obligation from `AutoDevDriving.swift:64-68`, which binds this method
        // even though this actor does not conform to that protocol: "a loop
        // that reaches its own end must make that observable." `advance()` may
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
        // gives: `pump()` steps over a refused run and admits the next
        // (`RunScheduler.swift:428-436`), so on a repository the session keeps
        // busy `.mergeWaitsForRepoToBeIdle` can otherwise never lift. Anything
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
                // in Done *before* the run (`BoardService.swift:196-226`) and
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

    /// Ends a session. Task 13 gives this the cancellations it also owes.
    private func finish(_ session: AutoDevSession) async {
        var ended = session
        ended.state = .finished
        ended.endedAt = clock()
        try? await store.saveAutoDevSession(ended)
    }
}
