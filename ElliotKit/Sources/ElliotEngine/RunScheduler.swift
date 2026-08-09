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
    case runOutput(runID: UUID, event: StreamEvent)
    case runStalled(runID: UUID, since: Date)
    case runFinished(runID: UUID, cardID: UUID?, state: RunState, outcome: VerifiedOutcome?)
    /// The pending queue changed. Pushed rather than polled — the UI must not
    /// ask a question whose answer only the scheduler knows.
    case queueChanged([QueuedRun])
}

/// Runs skills, at most a few at a time, respecting what can safely overlap.
public actor RunScheduler: RunLaunching {
    private let store: BoardStore
    private let toolConfig: ToolConfig
    private let verifier: Verifier
    /// `var`, not `let`: these were constructor constants nobody ever passed, so
    /// the only way to change them was to rebuild the app. See `setLimits`.
    private var limits: SchedulerLimits
    private var ceiling: SpendCeiling
    /// Today's spend, cached. Read from the store when it goes stale rather than
    /// on every admission: `canStart` runs once per pending run per `pump()`,
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
    private let harvester: ProposalHarvester
    /// `git status --porcelain` taken just before each analysis spawned, keyed
    /// by run. In memory only: if the app dies mid-run the baseline is gone and
    /// the sweep reports the sentinel as unchecked rather than guessing.
    private var treeBaselines: [UUID: String] = [:]
    private let git: GitClient

    private var live: [UUID: ClaudeRun] = [:]
    private var inFlight: [UUID: SkillRun] = [:]
    private var pending: [UUID] = []

    public weak var systemMover: (any SystemMoving)?

    public nonisolated let updates: AsyncStream<SchedulerUpdate>
    private nonisolated let continuation: AsyncStream<SchedulerUpdate>.Continuation

    public init(
        store: BoardStore,
        toolConfig: ToolConfig,
        verifier: Verifier,
        harvester: ProposalHarvester? = nil,
        limits: SchedulerLimits = .default,
        ceiling: SpendCeiling = .off
    ) {
        self.store = store
        self.toolConfig = toolConfig
        self.verifier = verifier
        self.harvester = harvester ?? ProposalHarvester(store: store, gh: GHClient(config: toolConfig))
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

    /// Changes the caps, and drains whatever the old ones were holding back.
    ///
    /// The `pump()` is the point. Without it, raising the limit would do nothing
    /// visible until some unrelated run happened to finish — the user would set
    /// four workers, watch two run, and conclude the setting was ignored.
    ///
    /// Lowering never kills anything: `canStart` is only consulted for runs that
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

    public var paused: Bool { isPaused }

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
        let analyses = inFlight.values.filter { $0.kind == .analyzeRepo }.count
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
    /// An analysis only reads, but it reads the working tree, so it must not
    /// overlap a merge in the same repo: it would see a moving target, and the
    /// git sentinel would fire on someone else's work. It gets its own lane
    /// because the cap below exists to keep two *builds* out of one `.build/`,
    /// and an analysis builds nothing.
    func canStart(_ run: SkillRun) -> Bool {
        refusal(for: run, overBudget: false) == nil
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
    /// per pending run per drain.
    func refusal(for run: SkillRun, overBudget: Bool) -> QueueRefusal? {
        if isPaused { return .paused }
        if overBudget { return .dailyCeilingReached }

        let sameRepo = inFlight.values.filter { $0.repoID == run.repoID }
        if sameRepo.contains(where: { $0.kind == .mergePR }) { return .mergeInFlightInRepo }

        if run.kind == .analyzeRepo {
            let analysesInFlight = inFlight.values.filter { $0.kind == .analyzeRepo }.count
            guard analysesInFlight >= limits.maxConcurrentAnalyses else { return nil }
            return .analysisCapReached(
                inFlight: analysesInFlight, cap: limits.maxConcurrentAnalyses)
        }

        let writersInFlight = inFlight.values.filter { $0.kind != .analyzeRepo }.count
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
        case .implementIssue, .analyzeRepo:
            return nil
        }
    }

    public func launch(runID: UUID) async {
        guard !pending.contains(runID), inFlight[runID] == nil else { return }
        pending.append(runID)
        await pump()
    }

    private func pump() async {
        // Read once per drain, not once per run. `canStart` is consulted for
        // every pending run and is deliberately synchronous; a SQL aggregate in
        // there would turn draining a queue of twenty into twenty queries.
        let overBudget = await isOverDailyCeiling()
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
            if let why = refusal(for: run, overBudget: overBudget) {
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
                    // a run queued since the last drain.
                    refusal: lastRefusals[runID]
                        ?? refusal(for: run, overBudget: false)
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
            updated.resultText = repoReadError.map {
                "Elliot could not read this run's repository: \($0.localizedDescription)"
            } ?? "The repository this run belongs to no longer exists."
            try? await store.saveRun(updated)
            continuation.yield(.runFinished(
                runID: run.id, cardID: run.cardID, state: .failed, outcome: nil
            ))
            return
        }

        let invocation = ClaudeInvocation(
            runID: run.id,
            prompt: run.prompt,
            cwd: repo.path,
            permissionMode: repo.permissionMode,
            extraAllowedTools: repo.extraAllowedTools,
            maxBudgetUSD: ceiling.perRunUSD
        )
        updated.argv = [toolConfig.claudePath] + invocation.arguments()

        let logURL = URL(fileURLWithPath: run.logPath)

        if updated.isAnalysis {
            // The prompt forbids modifying the repository and no CLI flag can
            // enforce it, so record the tree now and compare after. Do not
            // trust the instruction; check the outcome.
            treeBaselines[run.id] = await git.porcelainStatus(cwd: repo.path)
        }

        let claudeRun: ClaudeRun
        do {
            try? FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            claudeRun = try ClaudeRun.start(invocation: invocation, config: toolConfig, logURL: logURL)
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
            updated.resultText = error.localizedDescription
            try? await store.saveRun(updated)
            continuation.yield(.runFinished(
                runID: run.id, cardID: run.cardID, state: .failed, outcome: nil
            ))
            return
        }

        try? await store.saveRun(updated)
        live[run.id] = claudeRun
        // Refreshes the claim made at the top of this method with `argv`; it is
        // no longer what *makes* the claim. Moving it back down re-opens the
        // double spawn.
        inFlight[run.id] = updated
        continuation.yield(.runStarted(runID: run.id, cardID: run.cardID))

        Task { await self.consume(claudeRun, run: updated) }
    }

    private func consume(_ claudeRun: ClaudeRun, run: SkillRun) async {
        var finalOutcome: ClaudeRunOutcome?
        var stalled = false

        for await update in claudeRun.updates {
            switch update {
            case .started:
                break
            case .event(let event):
                continuation.yield(.runOutput(runID: run.id, event: event))
            case .stalled(let since):
                stalled = true
                continuation.yield(.runStalled(runID: run.id, since: since))
                await markStalled(run.id)
            case .finished(let outcome):
                finalOutcome = outcome
            }
        }
        _ = stalled
        await finish(run: run, outcome: finalOutcome)
    }

    private func markStalled(_ runID: UUID) async {
        guard var run = try? await store.run(id: runID), run.state == .running else { return }
        run.state = .stalled
        try? await store.saveRun(run)
    }

    private func finish(run: SkillRun, outcome: ClaudeRunOutcome?) async {
        live[run.id] = nil
        inFlight[run.id] = nil
        // The only moment the day's total moves. Invalidated rather than
        // recomputed: the `pump()` at the end of this method reads it back, and
        // doing it here would read a total that does not include this run yet.
        spentTodayCache = nil

        var updated = (try? await store.run(id: run.id)) ?? run
        updated.endedAt = Date()
        updated.exitCode = outcome?.exitCode
        updated.resultText = outcome?.result?.text ?? outcome?.stderr
        updated.totalCostUSD = outcome?.result?.totalCostUSD
        updated.numTurns = outcome?.result?.numTurns
        updated.permissionDenials = outcome?.result?.permissionDenials.map(\.toolName) ?? []
        updated.state = Self.state(for: outcome)

        // One split, in one place: a card run is verified against gh and writes
        // back to its card; an analysis run is harvested and writes proposals.
        // Letting `finish` acquire two personalities is how this method would
        // become unreadable.
        //
        // if/else rather than a ternary: `inout` arguments are not allowed in
        // one.
        var verified: VerifiedOutcome?
        if updated.isAnalysis {
            await completeAnalysisRun(&updated)
        } else {
            verified = await completeCardRun(&updated)
        }

        try? await store.saveRun(updated)
        continuation.yield(.runFinished(
            runID: run.id, cardID: updated.cardID, state: updated.state, outcome: verified
        ))
        await pump()
    }

    /// Verify against `gh`, then write what it said onto the card.
    private func completeCardRun(_ run: inout SkillRun) async -> VerifiedOutcome? {
        guard let cardID = run.cardID,
              let card = try? await store.card(id: cardID),
              let repo = try? await store.repo(id: run.repoID)
        else { return nil }

        // Verify even a cancelled run: implement-issue may well have opened the
        // pull request before it was stopped, and both skills are resume-safe.
        let verified = await verifier.verify(run: run, card: card, repo: repo)
        run.verifiedOutcome = verified
        await apply(verified, to: card)
        return verified
    }

    /// Harvest the artifact, then answer the sentinel's question.
    private func completeAnalysisRun(_ run: inout SkillRun) async {
        let baseline = treeBaselines.removeValue(forKey: run.id)

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

        if let baseline {
            let after = await git.porcelainStatus(cwd: repo.path)
            let changed = after != baseline
            // Explicit even when unchanged: a checked-and-clean tree (`false`)
            // must not read the same as a tree the sentinel never got to look
            // at (`nil`) — that collapse is exactly what let an orphaned run
            // masquerade as verified-clean.
            report.workingTreeChanged = changed
            if changed {
                report.workingTreeDiff = after
            }
        }

        run.analysisReport = report
    }

    static func state(for outcome: ClaudeRunOutcome?) -> RunState {
        guard let outcome else { return .failed }
        if outcome.wasTerminated { return .cancelled }
        if let result = outcome.result {
            if result.isError { return .failed }
            // A run that was refused a tool often finishes "success" having
            // worked around the gap. That is not a clean result.
            return result.permissionDenials.isEmpty ? .succeeded : .completedWithDenials
        }
        return outcome.exitCode == 0 ? .succeeded : .failed
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
        guard let claudeRun = live[runID] else {
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
        claudeRun.cancel()
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
}
