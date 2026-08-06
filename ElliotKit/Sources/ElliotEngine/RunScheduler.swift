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
}

/// Runs skills, at most a few at a time, respecting what can safely overlap.
public actor RunScheduler: RunLaunching {
    private let store: BoardStore
    private let toolConfig: ToolConfig
    private let verifier: Verifier
    /// `var`, not `let`: these were constructor constants nobody ever passed, so
    /// the only way to change them was to rebuild the app. See `setLimits`.
    private var limits: SchedulerLimits
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
        limits: SchedulerLimits = .default
    ) {
        self.store = store
        self.toolConfig = toolConfig
        self.verifier = verifier
        self.harvester = harvester ?? ProposalHarvester(store: store, gh: GHClient(config: toolConfig))
        self.limits = limits
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
        let sameRepo = inFlight.values.filter { $0.repoID == run.repoID }
        guard !sameRepo.contains(where: { $0.kind == .mergePR }) else { return false }

        if run.kind == .analyzeRepo {
            let analysesInFlight = inFlight.values.filter { $0.kind == .analyzeRepo }.count
            return analysesInFlight < limits.maxConcurrentAnalyses
        }

        let writersInFlight = inFlight.values.filter { $0.kind != .analyzeRepo }.count
        guard writersInFlight < limits.maxConcurrent else { return false }

        switch run.kind {
        case .mergePR:
            // Waits for an analysis too, at no extra cost: it is in sameRepo.
            return sameRepo.isEmpty
        case .createIssue:
            return !sameRepo.contains { $0.kind == .createIssue }
        case .implementIssue:
            return true
        case .analyzeRepo:
            return true
        }
    }

    public func launch(runID: UUID) async {
        guard !pending.contains(runID), inFlight[runID] == nil else { return }
        pending.append(runID)
        await pump()
    }

    private func pump() async {
        var stillPending: [UUID] = []
        for runID in pending {
            guard let run = try? await store.run(id: runID), run.state == .queued else { continue }
            if canStart(run) {
                await start(run)
            } else {
                stillPending.append(runID)
            }
        }
        pending = stillPending
    }

    // MARK: - Running

    private func start(_ run: SkillRun) async {
        guard let repo = try? await store.repo(id: run.repoID) else { return }

        var updated = run
        updated.state = .running
        updated.startedAt = Date()

        let invocation = ClaudeInvocation(
            runID: run.id,
            prompt: run.prompt,
            cwd: repo.path,
            permissionMode: repo.permissionMode,
            extraAllowedTools: repo.extraAllowedTools
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
        await apply(verified, to: card, run: run)
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
    private func apply(_ outcome: VerifiedOutcome, to card: Card, run: SkillRun) async {
        var card = card
        var systemMove: (ElliotModel.Column, MoveOrigin.SystemReason)?

        switch outcome {
        case .issueCreated(let number, let url):
            card.issueNumber = number
            card.issueURL = url
            card.lastError = nil

        case .noIssueCreated(let reason):
            card.lastError = reason

        case .prOpen(let number, let url, let isDraft, let branch):
            card.prNumber = number
            card.prURL = url
            card.branch = branch
            card.lastError = nil
            // implement-issue flips the PR ready as its last act, so this is
            // usually already true by the time the run exits.
            if !isDraft, card.column == .inProgress {
                systemMove = (.inReview, .prBecameReady)
            }

        case .merged:
            card.lastError = nil
            if card.column != .done { systemMove = (.done, .prMergedExternally) }

        case .notMerged(let reason), .unverified(let reason):
            card.lastError = reason

        case .closedUnmerged:
            card.lastError = "The pull request was closed without being merged."
        }

        try? await store.saveCard(card)
        if let (column, reason) = systemMove {
            await systemMover?.applySystemMove(cardID: card.id, to: column, reason: reason)
        }
    }

    // MARK: - Cancellation

    public func cancel(runID: UUID) async {
        guard let claudeRun = live[runID] else {
            pending.removeAll { $0 == runID }
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
