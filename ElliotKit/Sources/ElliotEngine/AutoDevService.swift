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

    /// One coalesced pass over every running session. Filled in by the next
    /// task; a no-op here so `start` has something to call.
    public func advance() async {}
}
