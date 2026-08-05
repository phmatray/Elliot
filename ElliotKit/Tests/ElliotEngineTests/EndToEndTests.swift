import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine

/// `ELLIOT_HOME` is unset by default, which points `StoreLocation` at the real
/// `~/Library/Application Support/Elliot` — a directory these tests have no
/// business reading from. `completeAnalysisRun` resolves its artifact path
/// through `StoreLocation`, not a parameter, so any test that runs an
/// analysis to completion needs this redirected. Set once per process, and
/// only if unset, so a shared process-wide home set by another suite is left
/// alone.
private let elliotHomeConfiguredForTests: Void = {
    guard ProcessInfo.processInfo.environment["ELLIOT_HOME"] == nil else { return }
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("elliot-e2e-tests-\(ProcessInfo.processInfo.processIdentifier)")
    setenv("ELLIOT_HOME", url.path, 1)
}()

/// The repository root, from this file's own location, so the tests use the
/// same `Scripts/` and `Fixtures/` a human would from a terminal.
private enum TestPaths {
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ElliotEngineTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // ElliotKit
        .deletingLastPathComponent()   // repo root

    static let fakeClaude = repoRoot.appendingPathComponent("Scripts/fake-claude.sh").path

    static func fixture(_ name: String) -> String {
        repoRoot.appendingPathComponent("Fixtures/stream-json/\(name)").path
    }
}

/// The whole stack against a fake `claude`: a card is dragged, the rule engine
/// decides, the scheduler spawns, the stream is parsed and logged, and the run
/// is recorded — without spending a token or touching GitHub.
private struct Stack {
    var store: BoardStore
    var board: BoardService
    var scheduler: RunScheduler
    var repo: Repo
    var home: URL

    static func make(
        fixture: String, extraEnv: [String: String] = [:], gitPath: String = "/usr/bin/false"
    ) async throws -> Stack {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elliot-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("runs"), withIntermediateDirectories: true
        )

        let store = try BoardStore.open(at: home.appendingPathComponent("elliot.sqlite"))
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        environment["FAKE_CLAUDE_FIXTURE"] = TestPaths.fixture(fixture)
        environment.merge(extraEnv) { _, new in new }

        let config = ToolConfig(
            claudePath: TestPaths.fakeClaude,
            // `false` so every verification fails cleanly rather than reaching
            // the network; this test is about the run mechanics. Callers that
            // exercise the git sentinel pass a real `git` instead.
            ghPath: "/usr/bin/false",
            gitPath: gitPath,
            environment: environment
        )
        let scheduler = RunScheduler(
            store: store, toolConfig: config, verifier: Verifier(gh: .init(config: config))
        )
        let board = BoardService(store: store, launcher: scheduler)
        await scheduler.setSystemMover(board)

        let repo = Repo(
            path: home.path, nameWithOwner: "phmatray/Elliot", displayName: "Elliot"
        )
        try await store.saveRepo(repo)
        return Stack(store: store, board: board, scheduler: scheduler, repo: repo, home: home)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: home) }

    /// Waits for a card's run to reach a terminal state.
    func awaitRun(cardID: UUID, timeout: Duration = .seconds(20)) async throws -> SkillRun {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let run = try await store.runs(cardID: cardID).first, run.state.isTerminal {
                return run
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw StackError.timedOut
    }

    /// Waits for an analysis run to reach a terminal state — it has no card to
    /// look it up by.
    func awaitRun(id: UUID, timeout: Duration = .seconds(20)) async throws -> SkillRun {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let run = try await store.run(id: id), run.state.isTerminal {
                return run
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw StackError.timedOut
    }

    enum StackError: Error { case timedOut }
}

@Suite("End to end", .serialized)
struct EndToEndTests {

    @Test("Dragging a story from Backlog to To Do runs create-issue for real")
    func backlogToTodoRunsTheSkill() async throws {
        let stack = try await Stack.make(fixture: "create-issue-success.ndjson")
        defer { stack.cleanUp() }

        let card = try await stack.board.createCard(
            repoID: stack.repo.id,
            title: "Run log",
            story: UserStory(
                role: "developer",
                want: "to see the run log inside the card",
                benefit: "I can diagnose without a terminal",
                acceptanceCriteria: ["the log streams live"]
            )
        )

        let result = try await stack.board.move(cardID: card.id, to: .todo, origin: .userDrag)
        guard case .moved(let runID?) = result else {
            Issue.record("expected a run, got \(result)")
            return
        }

        let run = try await stack.awaitRun(cardID: card.id)
        #expect(run.id == runID)
        #expect(run.kind == .createIssue)
        #expect(run.state == .succeeded)
        #expect(run.exitCode == 0)
        #expect(run.totalCostUSD == 0.1834)
        #expect(run.numTurns == 7)
        #expect(run.permissionDenials.isEmpty)

        // The prompt is what the skill actually receives.
        #expect(run.prompt == "/ai-migration-kit:create-issue As a developer, I want to see the "
            + "run log inside the card, so that I can diagnose without a terminal. "
            + "Acceptance criteria: 1) the log streams live")

        // The argv is reproducible by hand.
        #expect(run.argv.contains("--output-format"))
        #expect(run.argv.contains("stream-json"))
        #expect(run.argv.contains("--session-id"))
        #expect(run.argv.contains(run.id.uuidString.lowercased()))

        // Every raw line was written to the durable sink.
        let log = try String(contentsOfFile: run.logPath, encoding: .utf8)
        #expect(log.split(separator: "\n").count == 8)
        #expect(log.contains("https://github.com/phmatray/Elliot/issues/47"))

        // The card moved, and the audit records who asked.
        #expect(try await stack.store.card(id: card.id)?.column == .todo)
        let audits = try await stack.store.audits(cardID: card.id)
        #expect(audits.first?.origin == .userDrag)
        #expect(audits.first?.runID == runID)
    }

    @Test("A run refused a tool is not recorded as a plain success")
    func deniedRunIsFlagged() async throws {
        let stack = try await Stack.make(fixture: "denied.ndjson")
        defer { stack.cleanUp() }

        let card = try await stack.board.createCard(repoID: stack.repo.id, title: "Push something")
        _ = try await stack.board.move(cardID: card.id, to: .todo, origin: .userDrag)

        let run = try await stack.awaitRun(cardID: card.id)
        #expect(run.exitCode == 0)
        // The whole point: exit zero, is_error false, and still not a success.
        #expect(run.state == .completedWithDenials)
        #expect(run.permissionDenials == ["Bash"])
    }

    @Test("A crashing run is recorded as failed, with its stderr kept")
    func crashingRunIsRecorded() async throws {
        let stack = try await Stack.make(
            fixture: "create-issue-success.ndjson",
            extraEnv: ["FAKE_CLAUDE_MODE": "crash", "FAKE_CLAUDE_EXIT": "3"]
        )
        defer { stack.cleanUp() }

        let card = try await stack.board.createCard(repoID: stack.repo.id, title: "Anything")
        _ = try await stack.board.move(cardID: card.id, to: .todo, origin: .userDrag)

        let run = try await stack.awaitRun(cardID: card.id)
        #expect(run.state == .failed)
        #expect(run.exitCode == 3)
        #expect(run.resultText?.contains("simulated failure") == true)
    }

    @Test("Cancelling a run stops it and records the cancellation")
    func cancellingARun() async throws {
        let stack = try await Stack.make(
            fixture: "create-issue-success.ndjson",
            extraEnv: ["FAKE_CLAUDE_MODE": "trap"]
        )
        defer { stack.cleanUp() }

        let card = try await stack.board.createCard(repoID: stack.repo.id, title: "Long one")
        guard case .moved(let runID?) = try await stack.board.move(
            cardID: card.id, to: .todo, origin: .userDrag
        ) else {
            Issue.record("expected a run")
            return
        }

        // Let it actually start before pulling the plug.
        try await Task.sleep(for: .milliseconds(400))
        await stack.board.cancelRun(id: runID)

        let run = try await stack.awaitRun(cardID: card.id)
        #expect(run.state == .cancelled)
        #expect(run.exitCode == 143)
    }

    @Test("A move that triggers nothing spawns nothing")
    func inertMoveSpawnsNothing() async throws {
        let stack = try await Stack.make(fixture: "create-issue-success.ndjson")
        defer { stack.cleanUp() }

        var card = try await stack.board.createCard(repoID: stack.repo.id, title: "Already running")
        card.column = .inProgress
        card.issueNumber = 47
        card.prNumber = 279
        try await stack.store.saveCard(card)

        let result = try await stack.board.move(cardID: card.id, to: .inReview, origin: .userDrag)
        #expect(result == .moved(runID: nil))
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await stack.store.runs(cardID: card.id).isEmpty)
    }

    @Test("The launch sweep admits runs that died with the app")
    func reconcilerAdmitsOrphans() async throws {
        let stack = try await Stack.make(fixture: "create-issue-success.ndjson")
        defer { stack.cleanUp() }

        let card = try await stack.board.createCard(repoID: stack.repo.id, title: "Interrupted")
        var orphan = SkillRun(
            cardID: card.id, repoID: stack.repo.id, kind: .createIssue,
            prompt: "/ai-migration-kit:create-issue x", cwd: stack.repo.path,
            logPath: stack.home.appendingPathComponent("runs/orphan.ndjson").path,
            stderrPath: stack.home.appendingPathComponent("runs/orphan.log").path,
            createdAt: Date()
        )
        orphan.state = .running
        try await stack.store.saveRun(orphan)

        let config = ToolConfig(
            claudePath: TestPaths.fakeClaude, ghPath: "/usr/bin/false",
            gitPath: "/usr/bin/false", environment: [:]
        )
        let reconciler = Reconciler(
            store: stack.store,
            verifier: Verifier(gh: .init(config: config)),
            mover: stack.board,
            launcher: stack.scheduler
        )
        let summary = await reconciler.sweep()

        #expect(summary.orphanedRuns == 1)
        let recovered = try #require(try await stack.store.run(id: orphan.id))
        #expect(recovered.state == .failed)
        #expect(recovered.resultText?.contains("Elliot stopped") == true)
        // gh is unavailable here, so the outcome is honestly "unverified"
        // rather than a guess.
        if case .unverified = recovered.verifiedOutcome {} else {
            Issue.record("expected an unverified outcome, got \(String(describing: recovered.verifiedOutcome))")
        }
    }
}

@Suite("Analysis completion", .serialized)
struct AnalysisCompletionTests {

    /// The tri-state's whole point: a run the sentinel actually got to check
    /// reports `false` when the tree was untouched, and that must read as
    /// something other than the `nil` an orphan reports for "never checked".
    /// A test that only sees one of the two states cannot show they differ.
    @Test("A checked-clean run and an orphaned run report different things through the same field")
    func sentinelDistinguishesCleanFromUnchecked() async throws {
        _ = elliotHomeConfiguredForTests
        let stack = try await Stack.make(fixture: "create-issue-success.ndjson", gitPath: "/usr/bin/git")
        defer { stack.cleanUp() }

        // A directory of its own, distinct from `stack.home`: `stack.home` is
        // where Elliot writes this very run's own log file, and if the
        // "analyzed" repository were the same directory, that write would
        // dirty the tree the sentinel is watching — a false positive from
        // Elliot's own bookkeeping, not from anything the run did.
        let analyzedRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elliot-e2e-analyzed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: analyzedRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: analyzedRoot) }

        // A real, empty git repository, so "the tree didn't change" comes from
        // `git` actually saying so — not from a git binary that fails the same
        // way both before and after.
        _ = try? await ProcessRunner.run(
            executable: "/usr/bin/git", arguments: ["init"],
            cwd: analyzedRoot.path, environment: [:], timeout: .seconds(10)
        )

        let analyzedRepo = Repo(
            path: analyzedRoot.path, nameWithOwner: "phmatray/Analyzed", displayName: "Analyzed"
        )
        try await stack.store.saveRepo(analyzedRepo)

        let analysis = Analysis(repoID: analyzedRepo.id, angles: [.bugs], createdAt: Date())
        try await stack.store.saveAnalysis(analysis)

        let queued = SkillRun.analysis(
            repoID: analyzedRepo.id, analysisID: analysis.id, analysisAngle: .bugs,
            prompt: "…", cwd: analyzedRepo.path,
            logPath: stack.home.appendingPathComponent("runs/clean.ndjson").path,
            stderrPath: stack.home.appendingPathComponent("runs/clean.log").path,
            createdAt: Date()
        )
        try await stack.store.saveRun(queued)
        await stack.scheduler.launch(runID: queued.id)

        let finished = try await stack.awaitRun(id: queued.id)
        let cleanReport = try #require(finished.analysisReport)
        #expect(cleanReport.workingTreeChanged == false)

        // Now the other half: a run the app died on mid-flight. Its baseline
        // lived only in the scheduler's memory, so the reconciler that finds
        // it on the next launch has nothing to compare against.
        var orphan = SkillRun.analysis(
            repoID: analyzedRepo.id, analysisID: analysis.id, analysisAngle: .bugs,
            prompt: "…", cwd: analyzedRepo.path,
            logPath: stack.home.appendingPathComponent("runs/orphan-analysis.ndjson").path,
            stderrPath: stack.home.appendingPathComponent("runs/orphan-analysis.log").path,
            createdAt: Date()
        )
        orphan.state = .running
        try await stack.store.saveRun(orphan)

        let config = ToolConfig(
            claudePath: TestPaths.fakeClaude, ghPath: "/usr/bin/false",
            gitPath: "/usr/bin/false", environment: [:]
        )
        let reconciler = Reconciler(
            store: stack.store,
            verifier: Verifier(gh: .init(config: config)),
            mover: stack.board,
            launcher: stack.scheduler
        )
        let summary = await reconciler.sweep()
        #expect(summary.orphanedRuns == 1)

        let recoveredOrphan = try #require(try await stack.store.run(id: orphan.id))
        let orphanReport = try #require(recoveredOrphan.analysisReport)
        #expect(orphanReport.workingTreeChanged == nil)
        #expect(orphanReport.dropped.contains { $0.contains("stopped before") })

        // The distinction itself: same field, two different runs, and it does
        // not collapse to the same value.
        #expect(cleanReport.workingTreeChanged != orphanReport.workingTreeChanged)
    }
}
