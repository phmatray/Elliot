import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation

/// Launching and cancelling runs, as seen by the board.
///
/// A protocol so `BoardService` does not depend on the scheduler concretely —
/// the two would otherwise reference each other, since a finished run can
/// produce a system move.
public protocol RunLaunching: Sendable {
    func launch(runID: UUID) async
    func cancel(runID: UUID) async
}

/// Applying a move Elliot decided on its own.
public protocol SystemMoving: AnyObject, Sendable {
    func applySystemMove(cardID: UUID, to: ElliotModel.Column, reason: MoveOrigin.SystemReason) async
}

public enum SchedulerUpdate: Sendable {
    case runStarted(runID: UUID, cardID: UUID?)
    case runOutput(runID: UUID, event: RunEvent)
    /// What the turn amounted to, yielded the moment the runner says so and **before**
    /// `.runFinished`.
    ///
    /// ⛔ **Without this the terminal row can never render for a run anyone is watching.**
    /// `RunEvent` has no terminal case, deliberately — under ACP the stop reason arrives as a
    /// *response*, not a notification — so nothing in `runOutput` can carry it. `AppModel.liveLog`
    /// is never cleared, and `RunBox` takes the live tail whenever it is non-empty, falling back
    /// to disk only on `live.isEmpty`. So a finished ACP run keeps a non-empty live tail for the
    /// rest of the app session, never reaches the disk fold, and would show no terminal row at
    /// all. `.result` used to be a `StreamEvent` travelling through `runOutput`, becoming
    /// `.terminal(RunResult)` the instant it arrived; `RunsPaneLiveTests` asserts that row appears
    /// **mid-run**, which is the guarantee this case restores.
    ///
    /// Engine-local like every case here, so it does not bump `elliotProtocolVersion`.
    case runSummary(runID: UUID, summary: TurnSummary)
    case runStalled(runID: UUID, since: Date)
    /// The mirror of `.runStalled`: the run started talking again and is no
    /// longer holding a mark that nothing could take off.
    ///
    /// Engine-local, like every case here — it does not cross `ElliotIPC`, so
    /// this does not bump `elliotProtocolVersion`. `Protocol.swift` holds that
    /// value; a number written down beside code that does not change it is a
    /// number nothing keeps true.
    case runResumed(runID: UUID)
    case runFinished(runID: UUID, cardID: UUID?, state: RunState, outcome: VerifiedOutcome?)
    /// The pending queue changed. Pushed rather than polled — the UI must not
    /// ask a question whose answer only the scheduler knows.
    case queueChanged([QueuedRun])
}

/// Runs skills, at most a few at a time, respecting what can safely overlap.
public actor RunScheduler: RunLaunching, RunQueueReading, QueueReconsidering {
    private let store: BoardStore
    private let toolConfig: ToolConfig
    private let verifier: Verifier
    /// `var`, not `let`: these were constructor constants nobody ever passed, so
    /// the only way to change them was to rebuild the app. See `setLimits`.
    private var limits: SchedulerLimits
    private var ceiling: SpendCeiling
    /// Today's spend, cached. Read from the store when it goes stale rather than
    /// on every admission: `refusal` runs once per pending run per `pump()`,
    /// and a SQL aggregate there would turn a queue drain into N queries.
    /// Invalidated whenever a run finishes, which is the only moment it changes.
    private var spentTodayCache: Double?
    private var spentTodayDay: Date?
    /// Why each pending run was held, as of the last drain. Recorded rather than
    /// recomputed on read so the snapshot describes the decision that was
    /// actually made, not a fresh guess against a board that has since moved.
    private var lastRefusals: [UUID: QueueRefusal] = [:]
    /// Not persisted, deliberately: a relaunch should start working, not stay
    /// silently stopped.
    private var isPaused = false
    /// How long a spawned run may say nothing before the silence is announced.
    ///
    /// A constructor parameter rather than the constant `AgentRun.start`
    /// defaults to, and **not** part of `SchedulerLimits`: those are persisted as
    /// JSON, and a new non-optional field there would fail to decode every row
    /// written by an older build. This is construction-time only.
    ///
    /// It exists because the window was unreachable from a test, so the whole
    /// stall path had no end-to-end coverage at all — which is precisely how the
    /// mark stayed one-way. Nothing in the app passes anything but the default.
    private let idleTimeout: Duration
    private let harvester: ProposalHarvester
    /// The appraisal's harvester, beside the analysis's rather than inside it.
    ///
    /// Two read-only kinds, two harvesters, because they read two different
    /// artifacts and write two different things: `ProposalHarvester` reads an
    /// analysis's stories and files proposals; this one reads one card's
    /// appraisal and writes three fields onto that card. Sharing a type would
    /// mean a `kind` switch inside it, which is the split this task moved *out*
    /// of a boolean and into `finish`.
    private let appraiser: AppraisalHarvester
    /// `git status --porcelain` taken just before each read-only run spawned,
    /// keyed by run. In memory only: if the app dies mid-run the baseline is
    /// gone and the sweep reports the sentinel as unchecked rather than
    /// guessing.
    private var treeBaselines: [UUID: String] = [:]
    private let git: GitClient

    private var live: [UUID: AgentRun] = [:]
    private var inFlight: [UUID: SkillRun] = [:]
    private var pending: [UUID] = []

    /// Runs Elliot itself asked to stop, erased in `finish`.
    ///
    /// ⛔ **Elliot's own knowledge, and the only thing that can tell a cancel from a crash.**
    /// `ClaudeRunOutcome` carried `wasTerminated`, a flag `ChildProcess.terminate()` set on the way
    /// out, so the process itself said so. Under ACP a cancelled turn says so in its `stopReason`
    /// — but the SIGKILL backstop can kill the adapter before that answer arrives, and the child
    /// then dies on SIGTERM at 143, which is **indistinguishable from a crash**. Reading the exit
    /// code instead would mark every backstopped cancel as a failure, silently, on the board's most
    /// common deliberate action.
    ///
    /// ⛔ **Inserted on the live branch of `cancel(runID:)` only.** That method has three branches
    /// and only the live one reaches `finish`: a queued run goes through `discardQueued` and
    /// returns, an orphan row is written `.cancelled` in place and returns. Inserting at the top
    /// would leak one entry per queued-or-orphan cancel for the life of the process — the leak
    /// `treeBaselines`' own comment warns about.
    private var cancelRequested: Set<UUID> = []

    public weak var systemMover: (any SystemMoving)?
    /// Told after every run-ending path, once the row is written and (where the
    /// path reaches it) the queue has drained. Weak, like `systemMover`: the
    /// holder owns the scheduler.
    public weak var roundTrigger: (any RoundTriggering)?

    public nonisolated let updates: AsyncStream<SchedulerUpdate>
    private nonisolated let continuation: AsyncStream<SchedulerUpdate>.Continuation

    public init(
        store: BoardStore,
        toolConfig: ToolConfig,
        verifier: Verifier,
        harvester: ProposalHarvester? = nil,
        appraiser: AppraisalHarvester? = nil,
        limits: SchedulerLimits = .default,
        ceiling: SpendCeiling = .off,
        idleTimeout: Duration = AgentRun.defaultIdleTimeout
    ) {
        self.store = store
        self.toolConfig = toolConfig
        self.verifier = verifier
        self.idleTimeout = idleTimeout
        self.harvester = harvester ?? ProposalHarvester(store: store, gh: GHClient(config: toolConfig))
        // Defaulted from `store` exactly as `harvester` is.
        //
        // ⚠️ **Not, as this said, so that a test can watch the harvest without
        // spawning a `claude`** — that was never reachable and the branch's own
        // test says so: `completeAppraisalRun` is private, reached only through
        // `finish`, which is reached only through a real spawn. What the seam
        // buys is narrower and real. `AppraisalHarvester` is a struct, so it
        // cannot carry a spy; the one thing an injected one can differ in is
        // **which store the three fields land in**, and
        // `AppraisalEndToEndTests.theInjectedAppraiserIsTheOneThatWrites` varies
        // exactly that — a second database holding the same repository and card,
        // with both halves of its assertion flipping if `init` stops honouring
        // the parameter. It spawns a fake `claude`, like every other test there.
        self.appraiser = appraiser ?? AppraisalHarvester(store: store)
        self.limits = limits
        self.ceiling = ceiling
        self.git = GitClient(config: toolConfig)
        var continuation: AsyncStream<SchedulerUpdate>.Continuation!
        updates = AsyncStream(bufferingPolicy: .bufferingNewest(1024)) { continuation = $0 }
        self.continuation = continuation
    }

    public func setSystemMover(_ mover: any SystemMoving) {
        systemMover = mover
    }

    public func setRoundTrigger(_ trigger: any RoundTriggering) {
        roundTrigger = trigger
    }

    /// Changes the caps, and drains whatever the old ones were holding back.
    ///
    /// The `pump()` is the point. Without it, raising the limit would do nothing
    /// visible until some unrelated run happened to finish — the user would set
    /// four workers, watch two run, and conclude the setting was ignored.
    ///
    /// Lowering never kills anything: admission is only consulted for runs that
    /// have not started, so runs already in flight finish under the old cap and
    /// the new one takes effect as they drain.
    public func setLimits(_ limits: SchedulerLimits) async {
        self.limits = limits
        await pump()
    }

    public var currentLimits: SchedulerLimits { limits }

    /// Changes the ceiling and drains, for the same reason `setLimits` does:
    /// raising a ceiling that was refusing admission must release the queue now,
    /// not whenever something else happens to finish.
    public func setCeiling(_ ceiling: SpendCeiling) async {
        self.ceiling = ceiling
        spentTodayCache = nil
        await pump()
    }

    public var currentCeiling: SpendCeiling { ceiling }

    // MARK: - Queue commands

    /// Stops new runs starting. Runs already in flight finish normally — there
    /// is no version of "pause" that suspends a `claude` mid-turn, and pretending
    /// otherwise would be worse than not offering it.
    public func pause() async {
        guard !isPaused else { return }
        isPaused = true
        // Republished rather than left stale: every pending run's reason has
        // just changed to `.paused`, and a queue still showing "cap reached"
        // would send the reader to raise a limit that is not the block.
        await publishQueue()
    }

    public func resume() async {
        guard isPaused else { return }
        isPaused = false
        await pump()
    }

    /// `QueueReconsidering`: drain the queue because something *outside* the
    /// scheduler released an admission rule.
    ///
    /// The eighth caller of `pump()`, and the only one that is not the scheduler
    /// reacting to itself. The other seven all follow a change this actor made —
    /// a limit, a ceiling, a resume, a launch, a promotion, a run finishing —
    /// and `.mergeVerdictNotEstablished` is the one rule none of them can lift:
    /// a merge's reading ages out on a clock nobody rings and becomes current
    /// again only when `PRWatcher` writes a fresh `PRStatus` row. Without this,
    /// `refusal`'s own sentence — "the merge starts as soon as a current reading
    /// says the pull request is green" — was a promise with no keeper, and an
    /// unattended session's merge waited out its patience and was cancelled.
    ///
    /// Named for what it does to the *pending* queue and deliberately **not**
    /// `drain()`, which is 40 lines up and cancels every queued run: two verbs
    /// that both empty a queue, one by starting the work and one by discarding
    /// it, must not share a name.
    ///
    /// Idempotent, as the protocol requires — `pump()` is the same drain the
    /// scheduler already runs on every run-ending path.
    public func reconsiderQueue() async {
        await pump()
    }

    public var paused: Bool { isPaused }

    /// `paused` as `RunQueueReading` asks for it. Two spellings of one value,
    /// and deliberately not a rename: `AppModel.refreshOccupancy` reads `paused`
    /// directly, and a protocol requirement is a different thing from a
    /// property the app happens to read.
    public func queueIsPaused() async -> Bool { isPaused }

    /// Empties the queue without touching what is running.
    ///
    /// Each cleared run is marked `.cancelled` with an `endedAt`. A run that
    /// simply vanished from `pending` would keep its `.queued` state in the
    /// store, and the launch sweep would pick it up on the next start and
    /// resolve it against `gh` — reviving work the user just discarded.
    @discardableResult
    public func drain() async -> Int {
        let cleared = pending
        pending = []
        lastRefusals = [:]
        for runID in cleared { await discardQueued(runID) }
        // Emptying `pending` above is not enough, because this method suspends on
        // every row it cancels. A `launch` landing in one of those windows puts
        // its id back on the queue, and the `pump` it calls reads a row this loop
        // has not reached yet — still `.queued`, so admission legitimately holds
        // it. The row is then cancelled underneath it, leaving a `.cancelled` run
        // sitting in the queue for the board to offer again. Discarding what this
        // drain cleared is the postcondition the caller was promised.
        let discarded = Set(cleared)
        pending.removeAll { discarded.contains($0) }
        lastRefusals = lastRefusals.filter { pending.contains($0.key) }
        await publishQueue()
        return cleared.count
    }

    /// Takes one run out of the queue and marks it `.cancelled`.
    ///
    /// The single definition of *discarding queued work*, because there are two
    /// callers — `drain` and the pending branch of `cancel` — and they disagreed
    /// in three ways that all failed silently. `cancel` left the recorded
    /// refusal behind, never yielded `.runFinished`, and never published the
    /// queue: so cancelling one entry left its row on screen until the next
    /// `pump`, and left the card's `activeRunID` set in `AppModel`, which reads
    /// that event and nothing else to clear it.
    ///
    /// ⛔ **`pending` and `lastRefusals` are edited before the first `await`.**
    /// That ordering is `pump`'s documented invariant, not a style: a pump whose
    /// `store.run` read landed after the removal comes back holding a stale
    /// `.queued` row, and its own post-await containment check is what stops it
    /// spawning a run the user just discarded.
    ///
    /// Returns whether a queued row was actually cancelled, so a caller can say
    /// what it did rather than guess.
    @discardableResult
    private func discardQueued(_ runID: UUID) async -> Bool {
        pending.removeAll { $0 == runID }
        lastRefusals.removeValue(forKey: runID)
        guard var run = try? await store.run(id: runID), run.state == .queued else { return false }
        run.state = .cancelled
        run.endedAt = Date()
        try? await store.saveRun(run)
        continuation.yield(
            .runFinished(runID: runID, cardID: run.cardID, state: .cancelled, outcome: nil))
        // Deliberately no `roundTrigger` call here. This is the reader
        // cancelling a queued run, not one of it ending on its own; waking a
        // session to react to the reader's own cancellation is a decision
        // nobody has taken, and doing it silently here would take it.
        return true
    }

    /// Moves one entry to the head of the queue.
    ///
    /// Does not bypass admission: `pump()` still asks `refusal(for:)`, so a
    /// promoted run whose repository is merging waits exactly as it did. This
    /// changes the order runs are *considered* in, never the rules.
    public func promote(runID: UUID) async {
        guard let index = pending.firstIndex(of: runID), index != 0 else { return }
        pending.remove(at: index)
        pending.insert(runID, at: 0)
        await pump()
    }

    /// What the caps are actually holding right now, for the UI to show beside
    /// them: a stepper reading "4" means nothing without "2 in flight".
    public var occupancy: (writers: Int, analyses: Int) {
        let analyses = inFlight.values.filter(\.kind.isReadOnly).count
        return (inFlight.count - analyses, analyses)
    }

    // MARK: - Admission

    /// Whether a run may start now, given what is already going.
    ///
    /// Worktrees isolate git, so two `implement-issue` runs in one repo are
    /// safe. Two `merge-pr` runs are not — each merges to `main`, removes a
    /// worktree and deletes a branch. Two `create-issue` runs would each do
    /// duplicate detection against a repo the other is about to change.
    ///
    /// A read-only run — an analysis, or an appraisal of one card — only reads,
    /// but it reads the working tree, so it must not overlap a merge in the same
    /// repo: it would see a moving target, and the git sentinel would fire on
    /// someone else's work. Read-only runs get their own lane because the cap
    /// below exists to keep two *builds* out of one `.build/`, and neither of
    /// them builds anything.
    ///
    /// ⛔ **It derives both of `refusal`'s inputs rather than being handed them,
    /// and that is the whole fix.** This used to read `refusal(for: run,
    /// overBudget: false, mergeVerdict: .notDemanded)` — hardcoding *both*
    /// permissive values — so it answered `true` for a merge `pump()` refuses,
    /// while `SchedulerLimitsAdmissionTests` went on stating in prose that asking
    /// it was "the same thing `pump()` does". Measured on one scheduler and one
    /// run: a `.mergePR` run demanding a verified green whose `PRStatus` was
    /// 660 s old got `canStart == true` and stayed `.queued` through a real
    /// drain. It has no production caller today, which is exactly the condition
    /// under which a hardcoded safe value survives unnoticed — the next reader to
    /// reach for it as the admission oracle is a test author, and a test author
    /// is who it would mislead.
    ///
    /// ⚠️ **Deriving, not parameterising, is the deliberate half of that.**
    /// Adding `overBudget:` and `mergeVerdict:` parameters was tried first and is
    /// the worse fix: it makes every caller *supply* the answer, so the same
    /// caller that hardcoded a permissive value inside this method hardcodes it
    /// at the call site instead, and the trap moves rather than closes. Asking
    /// the store here costs two point-reads for a `.mergePR` run that demanded a
    /// green and an aggregate that is cached, which is affordable precisely
    /// because nothing consults this per pending run.
    ///
    /// That is also why `async` is fine here and would not be in `refusal`:
    /// `pump()` reads the ceiling once per *drain* and calls `mergeAdmission`
    /// itself inside its loop, where each `await` has to be paired with a
    /// `pending.contains` recheck. This has no queue to lose underneath it.
    func canStart(_ run: SkillRun) async -> Bool {
        refusal(
            for: run,
            overBudget: await isOverDailyCeiling(),
            mergeVerdict: await mergeAdmission(for: run, now: Date())
        ) == nil
    }

    /// What admission knows about a merge run's reading, as of this drain.
    ///
    /// Passed into `refusal(for:)` rather than read there, for exactly the
    /// reason `overBudget` is: the reading lives behind an `await` and that
    /// method is deliberately synchronous, because it is consulted once per
    /// pending run per drain.
    enum MergeAdmission: Sendable, Hashable {
        /// Not a merge, or the move that queued it demanded no verified green.
        /// Admission is exactly what it always was.
        case notDemanded
        /// It demanded a green, and the reading behind it is still current.
        case current
        /// It demanded a green, and the reading is missing or has aged past
        /// `PRStatus.maximumAge`. For a run that asked for a green, those two
        /// are the same answer.
        case notEstablished
    }

    /// The same decision as `canStart`, keeping the reason instead of throwing
    /// it away.
    ///
    /// `nil` means the run may start. Every branch below is a rule the engine
    /// already enforced; what is new is that it says *which* — a queue that
    /// stops moving with no reason given reads as a broken scheduler.
    ///
    /// `overBudget` is passed in rather than read here because the spend lives
    /// behind an `await` and this must stay synchronous: it is consulted once
    /// per pending run per drain. `mergeVerdict` is the same idea applied to
    /// the reading behind a merge that demanded a verified green.
    func refusal(for run: SkillRun, overBudget: Bool, mergeVerdict: MergeAdmission) -> QueueRefusal? {
        if isPaused { return .paused }
        if overBudget { return .dailyCeilingReached }
        // Third, and above the repository rules on purpose: no other rule can
        // release this one, so naming a cap here would send the reader to raise
        // a limit that is not the block.
        if mergeVerdict == .notEstablished { return .mergeVerdictNotEstablished }

        let sameRepo = inFlight.values.filter { $0.repoID == run.repoID }
        if sameRepo.contains(where: { $0.kind == .mergePR }) { return .mergeInFlightInRepo }

        if run.kind.isReadOnly {
            let readersInFlight = inFlight.values.filter(\.kind.isReadOnly).count
            guard readersInFlight >= limits.maxConcurrentAnalyses else { return nil }
            return .analysisCapReached(
                inFlight: readersInFlight, cap: limits.maxConcurrentAnalyses)
        }

        // ⚠ A negation, and the compiler does not check it. Inverted, every
        // appraisal consumes the writer cap and every writer skips it.
        // `SchedulerReadOnlyLaneTests` is the witness.
        let writersInFlight = inFlight.values.filter { !$0.kind.isReadOnly }.count
        guard writersInFlight < limits.maxConcurrent else {
            return .writerCapReached(inFlight: writersInFlight, cap: limits.maxConcurrent)
        }

        switch run.kind {
        case .mergePR:
            // Waits for an analysis too, at no extra cost: it is in sameRepo.
            return sameRepo.isEmpty ? nil : .mergeWaitsForRepoToBeIdle
        case .createIssue:
            return sameRepo.contains { $0.kind == .createIssue }
                ? .duplicateCreateIssueInRepo : nil
        case .implementIssue, .analyzeRepo, .appraiseCards:
            return nil
        }
    }

    public func launch(runID: UUID) async {
        guard !pending.contains(runID), inFlight[runID] == nil else { return }
        pending.append(runID)
        await pump()
    }

    private func pump() async {
        // Read once per drain, not once per run. `refusal` is consulted for
        // every pending run and is deliberately synchronous; a SQL aggregate in
        // there would turn draining a queue of twenty into twenty queries.
        let overBudget = await isOverDailyCeiling()
        // One clock for the whole drain, so every pending run is judged against
        // the same instant rather than one that creeps forward run by run.
        let now = Date()
        // The snapshot decides the *order* to consider; the queue itself is
        // edited in place below. `pending = stillPending` at the end of this
        // method is what dropped a run that `launch` appended while this pump
        // was suspended in `store.run(id:)`, and what resurrected one `drain`
        // had just cancelled. Both callers fire on their own schedule — a run
        // finishing while the user drags a card is the ordinary case.
        for runID in pending {
            // Already gone before we even read it — nothing to do, and no store
            // round trip worth spending. Purely a shortcut: the guard that
            // matters is the one below, after the suspension.
            guard pending.contains(runID) else { continue }
            // ⛔ `pending.contains` is re-checked *after* the await, and that
            // position is the whole point. `drain` and `cancel` both take their
            // id out of `pending` synchronously and only then suspend to mark the
            // row `.cancelled`, so a pump whose `store.run` read landed inside
            // that window comes back holding a stale `.queued` value. Deciding on
            // it spawns a `claude` for a run the user just discarded — and
            // `start` then saves `.running` over the `.cancelled` row, so the
            // cancellation disappears as well. For `merge-pr` that is a merge to
            // `main` after being told to stop. Checking containment only *before*
            // the read cannot see any of it.
            guard let run = try? await store.run(id: runID),
                  pending.contains(runID),
                  run.state == .queued
            else {
                pending.removeAll { $0 == runID }
                lastRefusals.removeValue(forKey: runID)
                continue
            }
            // The ceiling holds runs rather than cancelling them: tomorrow, or a
            // raised ceiling, releases the same queue untouched.
            let mergeVerdict = await mergeAdmission(for: run, now: now)
            // ⛔ Re-checked *again*, for the same reason as the recheck above:
            // `mergeAdmission` suspends on real store reads — a card read and a
            // `prStatus` read — for exactly the run kind this whole guard exists
            // for, so `drain`/`cancel` can land their synchronous
            // `pending.removeAll` in *this* window too, not only the one before
            // `store.run(id:)`. Skipping this would spawn a `claude` for a run
            // the user just discarded, one `await` later than the bug this
            // method already guards against. The invariant this loop depends on:
            // every `await` between the top of this loop and `start(run)` needs
            // its own `pending.contains` recheck immediately after it — a future
            // `await` inserted here without one reopens exactly this window.
            guard pending.contains(runID) else {
                lastRefusals.removeValue(forKey: runID)
                continue
            }
            if let why = refusal(for: run, overBudget: overBudget, mergeVerdict: mergeVerdict) {
                lastRefusals[runID] = why
            } else {
                // Removed *before* `start` suspends, so a re-entering pump
                // cannot pick the same id off the queue.
                pending.removeAll { $0 == runID }
                lastRefusals.removeValue(forKey: runID)
                await start(run)
            }
        }
        // Only reasons for runs still queued survive: a stale entry would
        // outlive its run and be read back by `queueSnapshot`.
        lastRefusals = lastRefusals.filter { pending.contains($0.key) }
        await publishQueue()
    }

    /// What is known about one pending run's reading, as of this drain.
    ///
    /// Called once per pending run from inside `pump`'s loop, where the run has
    /// already been read — not as a pre-pass over `pending`, which would read
    /// the store a second time for every id and contradict the comment above
    /// `overBudget`: read once per drain, not once per run. A card read and a
    /// `prStatus` read only happen for a `.mergePR` run that demanded a green;
    /// every other run is `.notDemanded` for the price of the `SkillRun` this
    /// caller already holds.
    ///
    /// `currentHeadOid: nil` deliberately. Establishing the head right now would
    /// be a network call inside a drain, and `PRWatcher` already re-reads the
    /// moment the head moves. What that leaves in force is the **age** rule,
    /// which is the one this guard exists for: by the time `pump()` admits a
    /// held merge, the reading that decided the move is structurally the most
    /// delayed one in the system.
    ///
    /// `?? nil` flattens the `T??` a `try?` around an optional-returning
    /// throwing call produces — the idiom `PRWatcher.refreshStatuses` already
    /// uses.
    private func mergeAdmission(for run: SkillRun, now: Date) async -> MergeAdmission {
        guard run.kind == .mergePR, run.demandsVerifiedGreen else { return .notDemanded }
        // A demanding merge with no card to check has *less* established about
        // it than one whose card lookup fails below, not more: `.notDemanded`
        // is "nothing was asked", and something was. Grouping the two here was
        // the bug — reachable today only by bypassing `SkillRun.card(...)`,
        // which every real merge run goes through, so the database's own
        // `cardID`/`analysisID` CHECK constraint is what actually stands
        // between this branch and a run that could reach it.
        guard let cardID = run.cardID else { return .notEstablished }
        guard let card = (try? await store.card(id: cardID)) ?? nil,
              let number = card.prNumber,
              let status = (try? await store.prStatus(repoID: run.repoID, prNumber: number)) ?? nil
        else {
            return .notEstablished
        }
        return status.resolved(now: now, currentHeadOid: nil).isStale ? .notEstablished : .current
    }

    /// The pending queue, in the order `pump()` will consider it, each entry
    /// carrying the rule that is holding it.
    public func queueSnapshot() async -> [QueuedRun] {
        var rows: [QueuedRun] = []
        for (index, runID) in pending.enumerated() {
            guard let run = try? await store.run(id: runID) else { continue }
            let repo = try? await store.repo(id: run.repoID)
            // Written out rather than `flatMap`: the closure would have to be
            // async, and `flatMap` takes a synchronous one.
            var card: Card?
            if let cardID = run.cardID { card = try? await store.card(id: cardID) }
            rows.append(
                QueuedRun(
                    runID: run.id,
                    cardID: run.cardID,
                    repoID: run.repoID,
                    repoName: repo?.nameWithOwner ?? "?",
                    cardTitle: card?.displayTitle,
                    kind: run.kind,
                    position: index + 1,
                    // The recorded reason, or the one that applies right now for
                    // a run queued since the last drain. `.notDemanded` here is
                    // not a claim about the run: this branch is only reached for
                    // a run queued *since* the last drain, whose reading has not
                    // been taken yet. The next drain records the real reason.
                    refusal: lastRefusals[runID]
                        ?? refusal(for: run, overBudget: false, mergeVerdict: .notDemanded)
                        ?? .writerCapReached(inFlight: 0, cap: limits.maxConcurrent),
                    queuedAt: run.createdAt
                )
            )
        }
        return rows
    }

    private func publishQueue() async {
        continuation.yield(.queueChanged(await queueSnapshot()))
    }

    /// Whether today's spend has reached the daily ceiling.
    ///
    /// Public so the UI can say *why* a queue is not moving. A queue that sits
    /// still with no reason given reads as a broken scheduler, and this is the
    /// one refusal a user cannot deduce from the board.
    public func isOverDailyCeiling() async -> Bool {
        guard ceiling.perDayUSD != nil else { return false }
        return ceiling.daylimitReached(spentToday: await spentToday())
    }

    private func spentToday() async -> Double {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        // The day boundary is part of the cache key. Without it a session left
        // open overnight keeps yesterday's total and refuses every run of the
        // new day — a bug that only appears after midnight, which is the worst
        // kind to find.
        if let cached = spentTodayCache, spentTodayDay == startOfDay { return cached }
        let spend = (try? await store.spend(since: startOfDay)) ?? .nothing
        spentTodayCache = spend.totalUSD
        spentTodayDay = startOfDay
        return spend.totalUSD
    }

    // MARK: - Running

    /// How a run is spawned.
    ///
    /// `static` and `internal` so it can be asserted without spawning anything:
    /// what a run is allowed to do is a rule, and a rule inside a spawn routine
    /// is a rule nothing can test. The two facts that differ for an appraisal —
    /// a tighter permission mode and the one directory outside the checkout it
    /// must be allowed to write — travel together here rather than as two `if`s
    /// in `start`, where only one of them would be remembered next time.
    ///
    /// ⚠️ `resumingAgentSession` is a **parameter** rather than something read here, and that is
    /// what keeps this function pure. `AgentInvocation.resumeFromAgentSession` is the *agent's*
    /// own session id, which lives on the predecessor `SkillRun` row — a store read, and an
    /// `async` one. `start(_:)` performs it and hands the answer down, so
    /// `AppraisalInvocationTests` can still assert the appraisal cap without spawning anything.
    static func invocation(
        for run: SkillRun, repo: Repo, perRunUSD: Double?, resumingAgentSession: String?
    ) -> AgentInvocation {
        let isAppraisal = run.kind == .appraiseCards
        return AgentInvocation(
            runID: run.id,
            prompt: run.prompt,
            // The **run's** cwd, not the repository's. They are the same value
            // for every run created today, and that is the point: a resumed run
            // has to spawn where its first attempt spawned, because Claude Code
            // keeps the transcript under a slug of that directory. Two sources
            // for one fact make the fork fail with "No conversation found",
            // which reads as an expired session rather than a wrong directory.
            cwd: run.cwd,
            permissionMode: isAppraisal
                ? PermissionMode.appraisal(repo: repo.permissionMode)
                : repo.permissionMode,
            extraAllowedTools: repo.extraAllowedTools,
            extraDirectories: isAppraisal
                ? [StoreLocation.appraisalRunDirectory(runID: run.id).path]
                : [],
            maxBudgetUSD: perRunUSD,
            resumeFromAgentSession: resumingAgentSession
        )
    }

    /// Creates every directory the invocation grants beyond the checkout.
    ///
    /// ⛔ `session/new`'s `additionalDirectories` on a path that is not there grants nothing, and
    /// it says nothing either — exactly as `--add-dir` did not: the only symptom is the agent
    /// reporting it could not write the file it was asked for — a failure that reads as the
    /// agent's, one layer away from the grant that looks perfectly correct.
    /// `StoreLocation.ensureDirectories()` creates `home`, `runs`, `analyses`
    /// and `screenshots`, measured, and not `analyses/appraisals/<runID>`.
    ///
    /// Driven off `extraDirectories` rather than off `run.kind`, so what is
    /// granted and what is created cannot drift apart, and a second kind with
    /// an artifact of its own gets this by construction. `cwd` is excluded for
    /// the same reason it is not in that list: the checkout is the operator's,
    /// and creating a registered path Elliot found missing would hide a
    /// repository that has moved.
    ///
    /// 0o700, matching `ensureDirectories`: these sit under `ELLIOT_HOME`,
    /// beside the socket and the token. `try?`, matching `AnalysisService`: a
    /// directory that could not be made costs the run its artifact and the
    /// harvester says so, which is a better outcome than refusing to spawn.
    static func prepareExtraDirectories(of invocation: AgentInvocation) {
        for path in invocation.extraDirectories {
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path, isDirectory: true),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    private func start(_ run: SkillRun) async {
        // ⛔ This guard and the assignment four lines down must stay adjacent
        // and await-free. That adjacency is the mutual exclusion: the actor
        // guarantees one job at a time, not one job to completion, and every
        // `await` below hands the actor to another pump. Until this claim moved
        // up here it happened *after* the spawn, so two pumps both saw the run
        // as startable and both spawned a `claude` for it — for `merge-pr`,
        // two agents each merging to `main` and deleting the same branch.
        // Measured before the move: 2 and 3 spawns of the same run, in 5 of 5
        // samples. `RunSchedulerShapeTests` fails if it drifts back down.
        guard inFlight[run.id] == nil else { return }
        var updated = run
        updated.state = .running
        updated.startedAt = Date()
        inFlight[run.id] = updated

        // Read with `do`/`catch` rather than `try?`, because the two ways this can
        // fail need different words. `try?` collapses "no such row" and "the read
        // threw" into one nil, and under the `skillRun.repoID` foreign key
        // (`onDelete: .cascade`) the *missing row* case cannot happen: such a run
        // cannot be inserted, and deleting a repository deletes its runs. So a
        // single message naming the row as absent would describe, to the operator,
        // the one cause that is impossible — while the cause that did occur went
        // unrecorded anywhere.
        var loadedRepo: Repo?
        var repoReadError: Error?
        do {
            loadedRepo = try await store.repo(id: run.repoID)
        } catch {
            repoReadError = error
        }

        guard let repo = loadedRepo else {
            // Nothing will ever call `finish` for this run, so the claim has to
            // be released here or the slot leaks for the life of the process.
            inFlight[run.id] = nil
            // And the row must reach a terminal state: `pump` has already taken
            // it out of `pending`, so a `.queued` row nothing holds is a run
            // that has silently disappeared until the next launch sweep.
            updated.state = .failed
            updated.endedAt = Date()
            // `.elliot`, not the agent: nothing was spawned, so there is no
            // agent to attribute this to. Recording it as prose is what put a
            // sentence Elliot wrote under the panel's "IT SAID" caption (#288).
            let sentence = repoReadError.map {
                "Elliot could not read this run's repository: \($0.localizedDescription)"
            } ?? "The repository this run belongs to no longer exists."
            updated.setClosing(.elliot(sentence))
            try? await store.saveRun(updated)
            continuation.yield(.runFinished(
                runID: run.id, cardID: run.cardID, state: .failed, outcome: nil
            ))
            // No `pump()` here — a failed spawn frees a writer slot that
            // nothing re-drains until an unrelated event. A pre-existing
            // scheduler defect, deliberately left alone rather than fixed in
            // passing on a branch about something else. The round trigger
            // still fires: the fact that this run ended is knowable right
            // now, and a session waiting on it should not sit through the
            // full stall window for nothing.
            await roundTrigger?.triggerRound()
            return
        }

        // The **agent's** session id of the attempt this one continues, not a `SkillRun.id`.
        // Read here rather than inside `invocation(for:)` so that function stays pure and
        // synchronous; `?? nil` flattens the `T??` a `try?` around an optional-returning throwing
        // call produces, the idiom `mergeAdmission` above already uses. A predecessor that never
        // got as far as `session/new` has none, and `nil` then means "start fresh" — which is
        // what a run with no transcript to fork can do.
        let resumingAgentSession: String?
        if let resumedFrom = run.resumedFrom {
            resumingAgentSession = ((try? await store.run(id: resumedFrom)) ?? nil)?.agentSessionID
        } else {
            resumingAgentSession = nil
        }

        let invocation = Self.invocation(
            for: run, repo: repo, perRunUSD: ceiling.perRunUSD,
            resumingAgentSession: resumingAgentSession
        )
        // The **adapter's** argv, not this invocation's: `AgentInvocation` renders no flags at
        // all, so there is nothing of its own to show. `AgentInvocation.displayArgv` carries the
        // record of what that costs — the same three tokens for every run.
        let agent = ACPAgentProcess(
            executable: toolConfig.adapterExecutable,
            arguments: toolConfig.adapterArguments,
            cwd: run.cwd,
            environment: toolConfig.environment
        )
        updated.argv = invocation.displayArgv(agent: agent)

        let logURL = URL(fileURLWithPath: run.logPath)

        if updated.kind.isReadOnly {
            // The prompt forbids modifying the repository and no CLI flag can
            // enforce it, so record the tree now and compare after. Do not
            // trust the instruction; check the outcome.
            //
            // `kind.isReadOnly` and not `isAnalysis`: an appraisal reads the
            // working tree under exactly the same unenforceable promise, and
            // the boolean answers "is this an analysis", which is false for it.
            // Armed on the boolean, an appraisal's report would say the tree
            // was never looked at — the tri-state's `nil`, which is the one
            // answer that must mean "nobody checked".
            treeBaselines[run.id] = await git.porcelainStatus(cwd: repo.path)
        }

        let agentRun: AgentRun
        do {
            try? FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Before the child, not after: the grant in `additionalDirectories`
            // above is inert until the directory it names exists.
            Self.prepareExtraDirectories(of: invocation)
            agentRun = try AgentRun.start(
                invocation: invocation, agent: agent, logURL: logURL, idleTimeout: idleTimeout
            )
        } catch {
            // The baseline was taken above whether or not the spawn survives;
            // `finish` is never reached from here, so nothing else would ever
            // clear it.
            treeBaselines[run.id] = nil
            // Same reason as the repo guard above: `finish` is never reached
            // from here, so the claim must be given back explicitly. Verified as
            // a gate: removing this line fails `aFailedSpawnReleasesTheClaim` on
            // both `activeRunCount` and `occupancy`.
            inFlight[run.id] = nil
            updated.state = .failed
            updated.endedAt = Date()
            // The spawn itself failed, so this is Elliot reporting a `Process`
            // that never started — not an agent's account of anything. It also
            // catches `AgentInvocationError`, whose two cases are refusals taken
            // *before* any child exists; both conform to `LocalizedError`
            // precisely so the sentence that lands here is one a person can act
            // on.
            updated.setClosing(.elliot(error.localizedDescription))
            try? await store.saveRun(updated)
            continuation.yield(.runFinished(
                runID: run.id, cardID: run.cardID, state: .failed, outcome: nil
            ))
            // Same reasoning as the repo-read guard above: no `pump()` (a
            // pre-existing scheduler defect, out of scope here), but the
            // round trigger still fires — the spawn failure is knowable
            // right now, not ten minutes from now.
            await roundTrigger?.triggerRound()
            return
        }

        try? await store.saveRun(updated)
        live[run.id] = agentRun
        // Refreshes the claim made at the top of this method with `argv`; it is
        // no longer what *makes* the claim. Moving it back down re-opens the
        // double spawn.
        inFlight[run.id] = updated
        continuation.yield(.runStarted(runID: run.id, cardID: run.cardID))

        Task { await self.consume(agentRun, run: updated) }
    }

    private func consume(_ agentRun: AgentRun, run: SkillRun) async {
        var finalOutcome: AgentRunOutcome?

        for await update in agentRun.updates {
            switch update {
            case .started:
                break
            case .event(let event):
                continuation.yield(.runOutput(runID: run.id, event: event))
            // Both directions yield *before* they await the write, and the two
            // are deliberately identical in shape: `AppModel` marks its copies
            // in place rather than re-reading, so a refresh racing the write
            // would read the row as it was and undo the answer.
            case .stalled(let since):
                continuation.yield(.runStalled(runID: run.id, since: since))
                await mark(.wentQuiet, on: run.id)
            case .resumed:
                continuation.yield(.runResumed(runID: run.id))
                await mark(.startedTalkingAgain, on: run.id)
            case .finished(let outcome):
                finalOutcome = outcome
                // ⛔ Yielded here, and **before** `.runFinished` below, because the terminal row
                // has no other route to a live reader. `RunEvent` carries no terminal case, so
                // nothing in `.runOutput` can say how the turn ended — and `AppModel.liveLog` is
                // never cleared, so a finished run keeps a non-empty live tail and never reaches
                // the disk fold that would otherwise supply one. See `SchedulerUpdate.runSummary`.
                if let summary = outcome.summary {
                    continuation.yield(.runSummary(runID: run.id, summary: summary))
                }
            }
        }
        await finish(run: run, outcome: finalOutcome)
    }

    /// Writes a silence notice onto the run's row, if the row will take it.
    ///
    /// One method for both directions, over `RunState.applying`. This was
    /// `markStalled`, whose guard was hand-copied into `AppModel.stalling` with
    /// a comment in each saying it was spelled the same way as the other — and
    /// only ever written in the one direction. The pair now lives once, in
    /// `ElliotModel`, and is called from here and from `AppModel.mark`.
    ///
    /// ⛔ The resume guard is load-bearing: a run can end while the recovery
    /// notice is in flight, and `.succeeded` is not `.stalled`, so it stays
    /// `.succeeded`. `cancel` is the sharp case — it writes `.cancelling` over
    /// whatever the run was, so the last byte a stalled run emits on its way out
    /// cannot drag it back to `.running` and hold its card against a move.
    ///
    /// Internal rather than private, like `canStart` and `refusal` above: this
    /// is the *durable* half of the mark, and a store write is worth measuring
    /// on its own rather than only through a spawned child. What reaches it —
    /// the `consume` switch — is measured end to end.
    func mark(_ notice: RunSilence, on runID: UUID) async {
        guard var run = try? await store.run(id: runID),
              let next = run.state.applying(notice)
        else { return }
        run.state = next
        try? await store.saveRun(run)
    }

    private func finish(run: SkillRun, outcome: AgentRunOutcome?) async {
        live[run.id] = nil
        inFlight[run.id] = nil
        // Erased unconditionally, and above every branch, for exactly the reason
        // `treeBaselines` is: a path that returned without erasing leaks one
        // entry per cancelled run for the life of the process.
        let wasCancelRequested = cancelRequested.remove(run.id) != nil
        // The only moment the day's total moves. Invalidated rather than
        // recomputed: the `pump()` at the end of this method reads it back, and
        // doing it here would read a total that does not include this run yet.
        spentTodayCache = nil

        var updated = (try? await store.run(id: run.id)) ?? run
        updated.endedAt = Date()
        updated.exitCode = outcome?.exitCode
        // The `??` this used to be lives in `ClosingRemark.of` now, because
        // choosing between the agent's words and the process's *is* the
        // attribution — and settling it here left the panel to assume it (#288).
        updated.setClosing(
            .of(agentText: outcome?.summary?.text, stderr: outcome?.stderr)
        )
        updated.totalCostUSD = outcome?.summary?.usage?.costUSD
        // ⚠️ **`nil`, never a guessed 1.** ACP reports no turn count at all: `num_turns` was
        // stream-json's own field and the protocol has nothing standing in for it. A synthesised
        // figure would read on screen exactly like a measured one.
        updated.numTurns = nil
        updated.permissionDenials = outcome?.summary?.denials ?? []
        updated.agentSessionID = outcome?.agentSessionID
        updated.stopReason = outcome?.summary?.stopReason
        updated.state = Self.state(for: outcome, cancelRequested: wasCancelRequested)

        // Computed here because this is the only place the outcome exists: by
        // the time anything downstream sees the row, `sessionResumeFailed` is
        // gone.
        //
        // Passed **to** `completeCardRun` rather than used to skip it. A run
        // that could not resume may still have left an issue or a pull request
        // behind on an earlier attempt, and the only thing that knows is `gh`.
        let resume = ResumeVerdict.of(
            resumedFrom: updated.resumedFrom,
            sessionResumeFailed: outcome?.sessionResumeFailed ?? false
        )

        // The baseline is erased for **every** run, above the routing rather
        // than inside a branch of it. The dictionary has exactly three sites —
        // the two in `start` and this one — and a fourth path returning without
        // an erasure leaks one entry per run for the lifetime of the process.
        let treeBaseline = treeBaselines.removeValue(forKey: run.id)

        // One split, in one place. A `switch` and not the `if updated.isAnalysis`
        // this was: the boolean routed an appraisal — which carries a `cardID` —
        // into `completeCardRun`, where `gh` is asked about an issue and a pull
        // request the card does not have. A sixth kind is now a compile error
        // here instead of a silent third meaning for an existing branch.
        //
        // `var verified` outside, because `inout` arguments are not allowed in a
        // ternary and the three branches do not all produce one.
        var verified: VerifiedOutcome?
        switch updated.kind {
        case .analyzeRepo:
            await completeAnalysisRun(&updated, baseline: treeBaseline)
        case .appraiseCards:
            await completeAppraisalRun(&updated, baseline: treeBaseline)
        case .createIssue, .implementIssue, .mergePR:
            verified = await completeCardRun(&updated, resume: resume)
        }

        try? await store.saveRun(updated)
        continuation.yield(.runFinished(
            runID: run.id, cardID: updated.cardID, state: updated.state, outcome: verified
        ))
        await pump()
        // Last, deliberately. By here the row is written, the in-flight set is
        // clear and the queue has been reconsidered under the new occupancy, so
        // a round triggered from this call can never read a half-finished run or
        // a queue that has not yet had its say.
        await roundTrigger?.triggerRound()
    }

    /// Verify against `gh`, then write what it said onto the card.
    private func completeCardRun(
        _ run: inout SkillRun, resume: ResumeVerdict
    ) async -> VerifiedOutcome? {
        guard let cardID = run.cardID,
              let card = try? await store.card(id: cardID),
              let repo = try? await store.repo(id: run.repoID)
        else { return nil }

        // Every run of this card, so the verifier can walk `resumedFrom` back to
        // the attempt the chain started with — or a refusal, when the read
        // failed and this run resumed. `ResumeWindow` holds both halves of that
        // rule and says at length why neither `?? []` nor a blanket refusal is
        // right.
        //
        // What the page bounds is worth stating precisely, because the two
        // framings have different remedies: it is `BoardStore.runs`' default
        // **page depth** of 100, not a chain length. The rows are this card's
        // newest runs of every kind, so a two-link chain is truncated just as
        // surely once 100 later runs exist on the card — a larger `limit`
        // answers one framing, a `since`-anchored or chain-following query the
        // other. Nothing here notices when it happens, though
        // `BoardStore.runCount(cardID:)` two functions away would make it
        // detectable.
        let verified: VerifiedOutcome
        if let cardRuns = await ResumeWindow.page(resumedFrom: run.resumedFrom, reading: {
            try await store.runs(cardID: cardID)
        }) {
            // Verify even a cancelled run: implement-issue may well have opened
            // the pull request before it was stopped, and both skills are
            // resume-safe.
            verified = await verifier.verify(
                run: run, card: card, repo: repo, cardRuns: cardRuns, resume: resume)
        } else {
            verified = .unverified(reason: ResumeWindow.unknownWindowReason)
        }
        run.verifiedOutcome = verified
        await apply(verified, to: card)
        return verified
    }

    /// Harvest the artifact, then answer the sentinel's question.
    ///
    /// The baseline arrives as a parameter rather than being taken from
    /// `treeBaselines` here: `finish` erases it for every run, above the
    /// routing, so no branch of that `switch` can be the one that forgets.
    private func completeAnalysisRun(_ run: inout SkillRun, baseline: String?) async {
        guard let analysisID = run.analysisID,
              let analysis = try? await store.analysis(id: analysisID),
              let repo = try? await store.repo(id: run.repoID)
        else {
            run.analysisReport = AnalysisRunReport(
                harvestSource: .none,
                dropped: ["The analysis this run belonged to could not be found."]
            )
            return
        }

        var report = await harvester.harvest(
            run: run,
            analysis: analysis,
            repo: repo,
            artifactURL: StoreLocation.analysisArtifactURL(analysisID: analysisID, runID: run.id)
        )
        await sealSentinel(&report, baseline: baseline, repoPath: repo.path)
        run.analysisReport = report
    }

    /// The same two steps for an appraisal: harvest the artifact, then answer
    /// the sentinel.
    ///
    /// It has no analysis to look up — that is the whole of the `cardID`
    /// decision — so the artifact is keyed on the run alone.
    private func completeAppraisalRun(_ run: inout SkillRun, baseline: String?) async {
        guard let repo = try? await store.repo(id: run.repoID) else {
            run.analysisReport = AnalysisRunReport(
                harvestSource: .none,
                dropped: ["The repository this appraisal ran in could not be found."]
            )
            return
        }

        var report = await appraiser.harvest(
            run: run,
            repo: repo,
            artifactURL: StoreLocation.appraisalArtifactURL(runID: run.id)
        )
        await sealSentinel(&report, baseline: baseline, repoPath: repo.path)
        run.analysisReport = report
    }

    /// Folds the git sentinel's answer onto a read-only run's report.
    ///
    /// One implementation for both read-only kinds. Two copies of these lines
    /// would be two copies of the argument in them, which is the shape #146
    /// caught in `ChildProcess`: when the *explanation* of an invariant has been
    /// copied word for word, the invariant has been copied too.
    ///
    /// Explicit even when unchanged: a checked-and-clean tree (`false`) must not
    /// read the same as a tree the sentinel never got to look at (`nil`) — that
    /// collapse is exactly what let an orphaned run masquerade as verified-clean.
    private func sealSentinel(
        _ report: inout AnalysisRunReport, baseline: String?, repoPath: String
    ) async {
        guard let baseline else { return }
        let after = await git.porcelainStatus(cwd: repoPath)
        let changed = after != baseline
        report.workingTreeChanged = changed
        if changed {
            report.workingTreeDiff = after
        }
    }

    /// The one fold from a finished run to a `RunState`.
    ///
    /// ⛔ `nonExecutionKind` folds **by value**, never by presence — `NonExecutionKind.isDenial`
    /// is the single implementation, `TurnSummary.denials` is filled from it by value, and this
    /// reads that rather than restating the list. Folding on presence would mark every cancelled
    /// run as one refused a tool, because a cancelled turn's in-flight calls carry `interrupted`
    /// or `cancelled`.
    ///
    /// ⚠️ `cancelRequested` is Elliot's own knowledge, not the agent's. `ClaudeRunOutcome`
    /// carried `wasTerminated`, a flag `ChildProcess.terminate()` set on the way out, so the
    /// process itself told us. Under ACP a cancelled turn says so in its `stopReason` — but the
    /// backstop can kill the adapter before that answer arrives, and a killed adapter is
    /// indistinguishable from a crashed one from outside. So the scheduler passes what it knows:
    /// it wrote `.cancelling` before it called `cancel()`.
    ///
    /// `summary.isClean` is called rather than re-implemented. `RunResult.isClean` existed and
    /// this function restated it inline anyway (`!isError && permissionDenials.isEmpty`) — two
    /// copies of one rule, the exact shape #146 catalogues.
    ///
    /// ⚠️ **One deliberate behaviour change, stated so nobody reads it as a slip.** The old tail
    /// was `return outcome.exitCode == 0 ? .succeeded : .failed`, so a `claude -p` that exited 0
    /// without ever emitting a terminal `result` counted as a success. Under ACP the absence of a
    /// terminal line means the **prompt response never arrived**, which is a run that did not
    /// finish, whatever the adapter's exit code says. So it reads `.failed` — or `.cancelled` if
    /// Elliot asked. `aRequestedCancelWithNoAnswer` pins both halves.
    static func state(for outcome: AgentRunOutcome?, cancelRequested: Bool) -> RunState {
        guard let outcome else { return cancelRequested ? .cancelled : .failed }
        if outcome.summary?.stopReason == "cancelled" { return .cancelled }
        guard let summary = outcome.summary else {
            // No terminal line at all: the response never arrived.
            return cancelRequested ? .cancelled : .failed
        }
        if summary.isError { return .failed }
        return summary.isClean ? .succeeded : .completedWithDenials
    }

    /// Writes what `gh` reported back onto the card.
    ///
    /// What an outcome *does* to a card is decided once, in `ElliotModel`; this
    /// reads the answer and performs the I/O. It used to hold its own switch,
    /// and the copies in `Reconciler` and `PRWatcher` had already drifted from
    /// it on whether a success clears `lastError`.
    private func apply(_ outcome: VerifiedOutcome, to card: Card) async {
        // `.live`: the world moved while Elliot was watching it happen.
        let result = outcome.applied(to: card, attribution: .live)

        if result.changed { try? await store.saveCard(result.card) }
        if let move = result.move {
            await systemMover?.applySystemMove(cardID: card.id, to: move.column, reason: move.reason)
        }
    }

    // MARK: - Cancellation

    /// Stops one run, whether it is queued or already going.
    ///
    /// Three cases, and they are genuinely different acts: a **queued** run is
    /// discarded through `discardQueued`, the one definition `drain` also uses;
    /// a **live** run gets a SIGTERM and is marked `.cancelling`, because its
    /// termination handler is what will finish the job; anything else is a row
    /// the store still believes is active with nothing behind it — a crash the
    /// launch sweep would otherwise resolve — and is closed out in place.
    public func cancel(runID: UUID) async {
        guard let agentRun = live[runID] else {
            if pending.contains(runID) {
                await discardQueued(runID)
                // Without this the discarded row stays on screen until something
                // else happens to pump the queue, which is the silent-drop class
                // the queue snapshot exists to end.
                await publishQueue()
                return
            }
            if var run = try? await store.run(id: runID), run.state.isActive {
                run.state = .cancelled
                run.endedAt = Date()
                try? await store.saveRun(run)
            }
            return
        }
        if var run = try? await store.run(id: runID) {
            run.state = .cancelling
            try? await store.saveRun(run)
        }
        // ⛔ Recorded here and nowhere else, immediately before the ask. Only this branch reaches
        // `finish`, which is the one place the set is erased — the two other branches above
        // return, so an insert at the top of this method would leak an entry per queued-or-orphan
        // cancel for the life of the process. And it must be recorded *at all*: under ACP the
        // backstop can kill the adapter before any `stopReason` arrives, and the exit code that
        // survives (143, on SIGTERM) is the same one a crash produces.
        cancelRequested.insert(runID)
        agentRun.cancel()
    }

    public func cancelAll() async {
        for runID in live.keys { await cancel(runID: runID) }
    }

    public var activeRunCount: Int { inFlight.count }

    /// Seeds the in-flight set so the admission rules can be exercised without
    /// spawning anything.
    func testOnlyMarkInFlight(_ run: SkillRun) {
        inFlight[run.id] = run
    }

    /// Releases a seeded in-flight run, so a test can express "the sibling
    /// finished" without spawning one.
    func testOnlyClearInFlight(_ runID: UUID) {
        inFlight[runID] = nil
    }

    /// Drains the queue the way a finished run does, without a finished run.
    func testOnlyDrain() async {
        await pump()
    }
}
