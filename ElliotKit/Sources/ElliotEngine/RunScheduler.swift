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
    case runStarted(runID: UUID, cardID: UUID)
    case runOutput(runID: UUID, event: StreamEvent)
    case runStalled(runID: UUID, since: Date)
    case runFinished(runID: UUID, cardID: UUID, state: RunState, outcome: VerifiedOutcome?)
}

/// Runs skills, at most a few at a time, respecting what can safely overlap.
public actor RunScheduler: RunLaunching {
    private let store: BoardStore
    private let toolConfig: ToolConfig
    private let verifier: Verifier
    private let maxConcurrent: Int

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
        maxConcurrent: Int = 2
    ) {
        self.store = store
        self.toolConfig = toolConfig
        self.verifier = verifier
        self.maxConcurrent = maxConcurrent
        var continuation: AsyncStream<SchedulerUpdate>.Continuation!
        updates = AsyncStream(bufferingPolicy: .bufferingNewest(1024)) { continuation = $0 }
        self.continuation = continuation
    }

    public func setSystemMover(_ mover: any SystemMoving) {
        systemMover = mover
    }

    // MARK: - Admission

    /// Whether a run may start now, given what is already going.
    ///
    /// Worktrees isolate git, so two `implement-issue` runs in one repo are
    /// safe. Two `merge-pr` runs are not — each merges to `main`, removes a
    /// worktree and deletes a branch. Two `create-issue` runs would each do
    /// duplicate detection against a repo the other is about to change.
    func canStart(_ run: SkillRun) -> Bool {
        guard inFlight.count < maxConcurrent else { return false }
        let sameRepo = inFlight.values.filter { $0.repoID == run.repoID }
        guard !sameRepo.contains(where: { $0.kind == .mergePR }) else { return false }

        switch run.kind {
        case .mergePR:
            return sameRepo.isEmpty
        case .createIssue:
            return !sameRepo.contains { $0.kind == .createIssue }
        case .implementIssue:
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
        let claudeRun: ClaudeRun
        do {
            try? FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            claudeRun = try ClaudeRun.start(invocation: invocation, config: toolConfig, logURL: logURL)
        } catch {
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

        // Verify even a cancelled run: implement-issue may well have opened the
        // pull request before it was stopped, and both skills are resume-safe.
        var verified: VerifiedOutcome?
        if let card = try? await store.card(id: run.cardID),
           let repo = try? await store.repo(id: run.repoID) {
            verified = await verifier.verify(run: updated, card: card, repo: repo)
            updated.verifiedOutcome = verified
            try? await store.saveRun(updated)
            await apply(verified!, to: card, run: updated)
        } else {
            try? await store.saveRun(updated)
        }

        continuation.yield(.runFinished(
            runID: run.id, cardID: run.cardID, state: updated.state, outcome: verified
        ))
        await pump()
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
