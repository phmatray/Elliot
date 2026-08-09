import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import TestSupport
import Testing

@testable import ElliotEngine

/// The repository root, from this file's own location, so the tests use the
/// same `Scripts/` and `Fixtures/` a human would from a terminal.
private enum TestPaths {
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ElliotEngineTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // ElliotKit
        .deletingLastPathComponent()   // repo root

    static let fakeClaude = repoRoot.appendingPathComponent("Scripts/fake-claude.sh").path
    static let fakeGH = repoRoot.appendingPathComponent("Scripts/fake-gh.sh").path

    static func fixture(_ name: String) -> String {
        repoRoot.appendingPathComponent("Fixtures/stream-json/\(name)").path
    }

    static func ghFixture(_ name: String) -> String {
        repoRoot.appendingPathComponent("Fixtures/gh/\(name)").path
    }
}

/// Writes a one-issue `gh issue list` payload whose `createdAt` is *now*.
///
/// `Verifier.verifyCreateIssue` only accepts an issue created since the run
/// started, so this cannot be a checked-in fixture with a frozen date — a
/// static file would make the test pass or fail according to the calendar.
private func issuesFixtureCreatedNow(title: String, number: Int, at directory: URL) throws -> String {
    let created = ISO8601DateFormatter().string(from: Date())
    let json = """
        [
          {
            "number": \(number),
            "title": "\(title)",
            "url": "https://github.com/phmatray/Elliot/issues/\(number)",
            "state": "OPEN",
            "createdAt": "\(created)",
            "body": "Filed by the run under test."
          }
        ]
        """
    let path = directory.appendingPathComponent("issues-created-now.json")
    try json.write(to: path, atomically: true, encoding: .utf8)
    return path.path
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
        fixture: String, extraEnv: [String: String] = [:], gitPath: String = "/usr/bin/false",
        ghPath: String = "/usr/bin/false", idleTimeout: Duration = ClaudeRun.defaultIdleTimeout
    ) async throws -> Stack {
        let home = TestHome.scratch("board-e2e")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("runs"), withIntermediateDirectories: true
        )
        try StoreLocation.ensureDirectories()

        let store = try BoardStore.open(at: home.appendingPathComponent("elliot.sqlite"))
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        environment["FAKE_CLAUDE_FIXTURE"] = TestPaths.fixture(fixture)
        environment.merge(extraEnv) { _, new in new }

        let config = ToolConfig(
            claudePath: TestPaths.fakeClaude,
            // `false` by default so every verification fails cleanly rather
            // than reaching the network; this test is about the run mechanics.
            // Callers that exercise the git sentinel pass a real `git` instead,
            // and callers that need `gh` to *answer* pass `TestPaths.fakeGH`.
            ghPath: ghPath,
            gitPath: gitPath,
            environment: environment
        )
        let scheduler = RunScheduler(
            store: store, toolConfig: config, verifier: Verifier(gh: .init(config: config)),
            idleTimeout: idleTimeout
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

    /// Waits for a card's run to reach a terminal state. On expiry it reports the
    /// state it actually saw, so a flake names its cause instead of "timedOut".
    func awaitRun(cardID: UUID, timeout: Duration = .seconds(20)) async throws -> SkillRun {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var lastSeen = "no run row"
        while ContinuousClock.now < deadline {
            if let run = try await store.runs(cardID: cardID).first {
                if run.state.isTerminal { return run }
                lastSeen = "\(run.state)"
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw StackError.timedOut(lastSeen: lastSeen)
    }

    /// Waits for an analysis run to reach a terminal state — it has no card to
    /// look it up by.
    func awaitRun(id: UUID, timeout: Duration = .seconds(20)) async throws -> SkillRun {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var lastSeen = "no run row"
        while ContinuousClock.now < deadline {
            if let run = try await store.run(id: id) {
                if run.state.isTerminal { return run }
                lastSeen = "\(run.state)"
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw StackError.timedOut(lastSeen: lastSeen)
    }

    enum StackError: Error { case timedOut(lastSeen: String) }
}

/// Nested under the shared parent from `AnalysisEndToEndTests.swift`: both
/// this suite and `AnalysisCompletionTests` below use `Stack`, which resolves
/// its paths through the one process-global `TestHome.root`, so they must not
/// run at the same time as each other or as the analysis end-to-end suite.
extension EndToEndSuites {

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
        ).card

        let result = try await stack.board.move(
            cardID: card.id, to: .todo, origin: .userDrag, requiresVerifiedGreen: false)
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

    @Test("A run that goes quiet and talks again is announced to the board both ways")
    func silenceAndRecoveryReachTheBoard() async throws {
        // The step between `ClaudeRun`'s stream and the board: `consume` routes
        // a notice to a `SchedulerUpdate` and to the row. Only `.stalled` had a
        // route, so the mark could be put on and never taken off — a `merge-pr`
        // that waited twenty-one minutes on CI and then produced its next tool
        // call kept the attention tint until it exited.
        //
        // ⛔ Nothing here measures a duration. The fixture's own pace makes the
        // silences — `FAKE_CLAUDE_DELAY_MS` sleeps after every line, so eight
        // lines give seven gaps that are followed by more output — the window is
        // short so the watchdog looks inside them, and what is asserted is the
        // *order* of what arrived.
        let stack = try await Stack.make(
            fixture: "create-issue-success.ndjson",
            extraEnv: ["FAKE_CLAUDE_DELAY_MS": "150"],
            idleTimeout: .milliseconds(20)
        )
        defer { stack.cleanUp() }

        // Hoisted out of the closure below: the stream is `Sendable`, the whole
        // stack is not, and this is the only member the collector needs.
        let updates = stack.scheduler.updates

        let card = try await stack.board.createCard(
            repoID: stack.repo.id,
            title: "A run that talks after a long silence",
            story: UserStory(
                role: "developer",
                want: "a stalled run to stop being stalled when it talks again",
                benefit: "silence still means something",
                acceptanceCriteria: ["the mark clears"]
            )
        ).card
        _ = try await stack.board.move(
            cardID: card.id, to: .todo, origin: .userDrag, requiresVerifiedGreen: false)

        let silences = try await withTimeout(.seconds(45)) { () -> [RunSilence] in
            var seen: [RunSilence] = []
            for await update in updates {
                switch update {
                case .runStalled: seen.append(.wentQuiet)
                case .runResumed: seen.append(.startedTalkingAgain)
                case .runFinished: return seen
                // Written out rather than `default`, so a case added to
                // `SchedulerUpdate` has to be considered here rather than
                // silently ignored by a collector that judges an ordering.
                case .runStarted, .runOutput, .queueChanged: break
                }
            }
            return seen
        }

        #expect(!silences.isEmpty, "the watchdog never looked inside a gap")
        #expect(
            silences.contains(.startedTalkingAgain),
            Comment(rawValue: "the run talked again and the board heard only \(silences)")
        )
        #expect(silences.first == .wentQuiet, "a recovery cannot precede a silence")
        let alternates = zip(silences, silences.dropFirst()).allSatisfy { $0 != $1 }
        #expect(alternates, Comment(rawValue: "notices did not alternate: \(silences)"))
    }

    /// Pins the behaviour the scheduler already had, so the refactor that moves
    /// this decision into `ElliotModel` has something to be measured against.
    /// It is `Reconciler` and `PRWatcher` that lacked the error-clearing, not
    /// this path — see their own tests below.
    @Test("A verified success clears the error a previous failure left on the card")
    func schedulerClearsTheStaleErrorOnSuccess() async throws {
        let ghHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("elliot-gh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ghHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ghHome) }

        let title = "Streaming run log inside the card"
        let issues = try issuesFixtureCreatedNow(title: title, number: 4242, at: ghHome)

        let stack = try await Stack.make(
            fixture: "create-issue-success.ndjson",
            extraEnv: ["FAKE_GH_ISSUES": issues],
            ghPath: TestPaths.fakeGH
        )
        defer { stack.cleanUp() }

        var card = try await stack.board.createCard(
            repoID: stack.repo.id,
            title: title,
            story: UserStory(
                role: "developer",
                want: "to see the run log inside the card",
                benefit: "I can diagnose without a terminal",
                acceptanceCriteria: ["the log streams live"]
            )
        ).card

        // The banner an earlier, failed attempt left behind.
        card.lastError = "create-issue exited 1"
        try await stack.store.saveCard(card)

        _ = try await stack.board.move(
            cardID: card.id, to: .todo, origin: .userDrag, requiresVerifiedGreen: false)
        let run = try await stack.awaitRun(cardID: card.id)
        #expect(run.state == .succeeded)

        let after = try #require(try await stack.store.card(id: card.id))
        #expect(after.issueNumber == 4242)
        #expect(after.issueURL == "https://github.com/phmatray/Elliot/issues/4242")
        #expect(after.lastError == nil)
        // `.issueCreated` implies no move: the card stays where the drag put it.
        #expect(after.column == .todo)
    }

    @Test("A run refused a tool is not recorded as a plain success")
    func deniedRunIsFlagged() async throws {
        let stack = try await Stack.make(fixture: "denied.ndjson")
        defer { stack.cleanUp() }

        let card = try await stack.board.createCard(repoID: stack.repo.id, title: "Push something").card
        _ = try await stack.board.move(
            cardID: card.id, to: .todo, origin: .userDrag, requiresVerifiedGreen: false)

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

        let card = try await stack.board.createCard(repoID: stack.repo.id, title: "Anything").card
        _ = try await stack.board.move(
            cardID: card.id, to: .todo, origin: .userDrag, requiresVerifiedGreen: false)

        let run = try await stack.awaitRun(cardID: card.id)
        #expect(run.state == .failed)
        #expect(run.exitCode == 3)
        #expect(run.resultText?.contains("simulated failure") == true)
        // ⛔ And it is recorded as the process's, not the agent's. This is the
        // whole of #288 measured through a real spawn: the child died before
        // any terminal event, so what survives is stderr, and the panel used to
        // caption it "IT SAID" in demoted italic — an inversion of the board's
        // central rule inside the one block built to show it.
        #expect(run.resultSource == .stderr)
        #expect(run.closing?.isHearsay == false)
        #expect(RunVerdict.of(run).itSaid == nil)
    }

    @Test("Cancelling a run stops it and records the cancellation")
    func cancellingARun() async throws {
        let ready = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elliot-ready-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: ready) }

        let stack = try await Stack.make(
            fixture: "create-issue-success.ndjson",
            extraEnv: ["FAKE_CLAUDE_MODE": "trap", "FAKE_CLAUDE_READY": ready.path]
        )
        defer { stack.cleanUp() }

        let card = try await stack.board.createCard(repoID: stack.repo.id, title: "Long one").card
        guard case .moved(let runID?) = try await stack.board.move(
            cardID: card.id, to: .todo, origin: .userDrag, requiresVerifiedGreen: false
        ) else {
            Issue.record("expected a run")
            return
        }

        // Wait on the fact that the child is trap-protected, not on a duration:
        // exit 143 only exists once the trap is installed, and under load a
        // fixed sleep can expire before bash gets there.
        try await withTimeout(.seconds(5)) {
            while !FileManager.default.fileExists(atPath: ready.path) {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        await stack.board.cancelRun(id: runID)

        let run = try await stack.awaitRun(cardID: card.id)
        #expect(run.state == .cancelled)
        #expect(run.exitCode == 143)
    }

    /// Criterion 2 of #333, asserted end to end for the first time.
    ///
    /// `RunScheduler` has always read `repo.permissionMode` and
    /// `repo.extraAllowedTools` at spawn, and `ClaudeInvocation.arguments()` has
    /// always emitted both flags — but nothing ever *wrote* either column, so
    /// every run in the suite's history was made under the same defaults and the
    /// path was never exercised with anything else. This pins the half of the
    /// feature that was already built.
    ///
    /// Asserted positionally rather than with `contains`, because an argument
    /// landing next to the wrong flag is exactly what `contains` cannot see.
    @Test("A repository's run terms reach the spawn")
    func runTermsReachTheSpawn() async throws {
        let stack = try await Stack.make(fixture: "create-issue-success.ndjson")
        defer { stack.cleanUp() }

        var repo = stack.repo
        repo.permissionMode = .acceptEdits
        repo.extraAllowedTools = ["Read", "Bash(git status *)"]
        try await stack.store.saveRepo(repo)

        let card = try await stack.board.createCard(repoID: repo.id, title: "Tightened").card
        _ = try await stack.board.move(
            cardID: card.id, to: .todo, origin: .userDrag, requiresVerifiedGreen: false)
        let run = try await stack.awaitRun(cardID: card.id)

        let mode = try #require(run.argv.firstIndex(of: "--permission-mode"))
        #expect(run.argv[mode + 1] == "acceptEdits")

        let tools = try #require(run.argv.firstIndex(of: "--allowedTools"))
        #expect(run.argv[tools + 1] == "Read,Bash(git status *)")
    }

    /// The other half of the same criterion, and the reason `ExtraAllowedTools`
    /// exists: an empty list must produce **no flag at all**, so a list holding
    /// one blank string is not "no tools" but `--allowedTools ""`.
    @Test("A repository allowing no extra tools passes no such flag")
    func noExtraToolsMeansNoFlag() async throws {
        let stack = try await Stack.make(fixture: "create-issue-success.ndjson")
        defer { stack.cleanUp() }

        var repo = stack.repo
        repo.extraAllowedTools = ExtraAllowedTools.normalise(["  ", ""])
        try await stack.store.saveRepo(repo)

        let card = try await stack.board.createCard(repoID: repo.id, title: "Untightened").card
        _ = try await stack.board.move(
            cardID: card.id, to: .todo, origin: .userDrag, requiresVerifiedGreen: false)
        let run = try await stack.awaitRun(cardID: card.id)

        #expect(!run.argv.contains("--allowedTools"))
        #expect(!run.argv.contains(""))
    }

    @Test("A move that triggers nothing spawns nothing")
    func inertMoveSpawnsNothing() async throws {
        let stack = try await Stack.make(fixture: "create-issue-success.ndjson")
        defer { stack.cleanUp() }

        var card = try await stack.board.createCard(repoID: stack.repo.id, title: "Already running").card
        card.column = .inProgress
        card.issueNumber = 47
        card.prNumber = 279
        try await stack.store.saveCard(card)

        let result = try await stack.board.move(
            cardID: card.id, to: .inReview, origin: .userDrag, requiresVerifiedGreen: false)
        #expect(result == .moved(runID: nil))
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await stack.store.runs(cardID: card.id).isEmpty)
    }

    @Test("The launch sweep admits runs that died with the app")
    func reconcilerAdmitsOrphans() async throws {
        let stack = try await Stack.make(fixture: "create-issue-success.ndjson")
        defer { stack.cleanUp() }

        let card = try await stack.board.createCard(repoID: stack.repo.id, title: "Interrupted").card
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
        // Elliot's own sentence about a child that died with it. The agent
        // never spoke — that is what the sentence *says* — so it must not be
        // attributed to it (#288).
        #expect(recovered.resultSource == .elliot)
        #expect(RunVerdict.of(recovered).itSaid == nil)
        // gh is unavailable here, so the outcome is honestly "unverified"
        // rather than a guess.
        if case .unverified = recovered.verifiedOutcome {} else {
            Issue.record("expected an unverified outcome, got \(String(describing: recovered.verifiedOutcome))")
        }
    }

    /// A `Reconciler` over the same store, with `gh` answering from a fixture.
    private func reconciler(for stack: Stack, prs: String) -> Reconciler {
        let config = ToolConfig(
            claudePath: TestPaths.fakeClaude, ghPath: TestPaths.fakeGH,
            gitPath: "/usr/bin/false",
            environment: [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "FAKE_GH_PRS": TestPaths.ghFixture(prs),
            ]
        )
        return Reconciler(
            store: stack.store,
            verifier: Verifier(gh: .init(config: config)),
            mover: stack.board,
            launcher: stack.scheduler
        )
    }

    /// Seeds a card mid-flight, as a crash would have left it. Written straight
    /// to the store on purpose: moving it through `BoardService` would spawn the
    /// very run this test is pretending died.
    private func seedInterruptedCard(
        in stack: Stack, column: Column, issue: Int, lastError: String? = nil
    ) async throws -> Card {
        var card = try await stack.board.createCard(repoID: stack.repo.id, title: "Interrupted").card
        card.column = column
        card.issueNumber = issue
        card.lastError = lastError
        try await stack.store.saveCard(card)

        var orphan = SkillRun(
            cardID: card.id, repoID: stack.repo.id, kind: .implementIssue,
            prompt: "/ai-migration-kit:implement-issue \(issue)", cwd: stack.repo.path,
            logPath: stack.home.appendingPathComponent("runs/orphan.ndjson").path,
            stderrPath: stack.home.appendingPathComponent("runs/orphan.log").path,
            createdAt: Date()
        )
        orphan.state = .running
        try await stack.store.saveRun(orphan)
        return card
    }

    /// **AC4.** The bug this issue exists to close: `implement-issue` fails and
    /// writes `lastError`, Elliot is quit mid-run, and on relaunch `gh` reports
    /// the pull request *was* opened before the crash. The card must reach In
    /// Review clean — the error describes a run that has since been disproved.
    @Test("A card reconciled at launch no longer carries the failed run's error")
    func reconciledCardDropsTheStaleError() async throws {
        let stack = try await Stack.make(fixture: "create-issue-success.ndjson")
        defer { stack.cleanUp() }

        let card = try await seedInterruptedCard(
            in: stack, column: .inProgress, issue: 102, lastError: "implement-issue exited 1"
        )
        let summary = await reconciler(for: stack, prs: "prs-basic.json").sweep()

        #expect(summary.orphanedRuns == 1)
        #expect(summary.cardsCorrected == 1)

        let after = try #require(try await stack.store.card(id: card.id))
        #expect(after.lastError == nil)
        #expect(after.prNumber == 201)
        #expect(after.prURL == "https://github.com/phmatray/Elliot/pull/201")
        #expect(after.branch == "feat/102-the-thing")
        #expect(after.column == .inReview)

        // The launch sweep records `.reconciliation`, not `.prBecameReady`:
        // the board is catching up, it did not watch this happen. That
        // difference is true, it is persisted, and it must survive.
        let audits = try await stack.store.audits(cardID: card.id)
        #expect(audits.first?.origin == .system(reason: .reconciliation))
    }

    /// A card already in Done gains no *move* from a merged pull request — but
    /// since #139 it does gain the three fields, so the sweep really did
    /// correct something and says so.
    ///
    /// ⚠️ This assertion read `cardsCorrected == 0` until #139, and the state it
    /// seeds is precisely the defect #139 exists to close: a Done card holding
    /// only an issue number, with no link to the pull request that closed it.
    /// The old zero was truthful about the old code and about nothing else —
    /// it described a card the board could not explain. The invariant it was
    /// written to protect (a summary must not overstate what it did) is intact
    /// and now lives in `reconcilerDoesNotCountRealNoOps` below, which seeds a
    /// card that has *nothing left to learn*.
    @Test("A merged pull request teaches a Done card which pull request closed it")
    func reconcilerRecordsThePullRequestOnADoneCard() async throws {
        let stack = try await Stack.make(fixture: "create-issue-success.ndjson")
        defer { stack.cleanUp() }

        let card = try await seedInterruptedCard(in: stack, column: .done, issue: 104)
        let summary = await reconciler(for: stack, prs: "prs-merged.json").sweep()

        #expect(summary.orphanedRuns == 1)
        #expect(summary.cardsCorrected == 1)

        let after = try #require(try await stack.store.card(id: card.id))
        #expect(after.column == .done)
        #expect(after.prNumber == 203)
        #expect(after.prURL == "https://github.com/phmatray/Elliot/pull/203")
        #expect(after.branch == "feat/104-already-landed")
        // Fields, but no move — it was already in Done, so nothing was moved
        // and nothing is recorded in the history.
        #expect(try await stack.store.audits(cardID: card.id).isEmpty)
    }

    /// The invariant the test above used to carry: `cardsCorrected` counts what
    /// changed, never what was merely looked at. The old switch wrote nothing,
    /// set no move, then fell through to `return true`. A launch summary that
    /// overstates what it did is the one thing a summary must not do.
    ///
    /// Seeded with the pull request's fields already on the card, which is what
    /// makes this a genuine no-op after #139 rather than an artefact of the
    /// outcome having had nothing to offer.
    @Test("A merged pull request on a Done card that already names it corrects nothing")
    func reconcilerDoesNotCountRealNoOps() async throws {
        let stack = try await Stack.make(fixture: "create-issue-success.ndjson")
        defer { stack.cleanUp() }

        var card = try await seedInterruptedCard(in: stack, column: .done, issue: 104)
        card.prNumber = 203
        card.prURL = "https://github.com/phmatray/Elliot/pull/203"
        card.branch = "feat/104-already-landed"
        try await stack.store.saveCard(card)

        let summary = await reconciler(for: stack, prs: "prs-merged.json").sweep()

        #expect(summary.orphanedRuns == 1)
        #expect(summary.cardsCorrected == 0)

        let after = try #require(try await stack.store.card(id: card.id))
        #expect(after.column == .done)
        #expect(try await stack.store.audits(cardID: card.id).isEmpty)
    }

    // MARK: - PRWatcher

    private func pullRequest(
        number: Int, issue: Int, state: String, mergedAt: Date? = nil
    ) -> GHPullRequest {
        GHPullRequest(
            number: number,
            url: "https://github.com/phmatray/Elliot/pull/\(number)",
            title: "feat(app): the thing issue \(issue) asked for",
            headRefName: "feat/\(issue)-the-thing",
            isDraft: false,
            state: state,
            mergedAt: mergedAt
        )
    }

    private func watcher(for stack: Stack) -> PRWatcher {
        let config = ToolConfig(
            claudePath: TestPaths.fakeClaude, ghPath: "/usr/bin/false",
            gitPath: "/usr/bin/false", environment: [:]
        )
        // `reconcile` is handed its pull requests directly, so this client is
        // never called — the sighting is the unit under test, not the fetch.
        return PRWatcher(store: stack.store, gh: .init(config: config), mover: stack.board)
    }

    /// The identical hole `Reconciler` had, on the identical field: the watcher
    /// moved the card to In Review and left the failed run's banner on it.
    @Test("A card the watcher sends to In Review no longer carries the failed run's error")
    func watcherClearsTheStaleError() async throws {
        let stack = try await Stack.make(fixture: "create-issue-success.ndjson")
        defer { stack.cleanUp() }

        var card = try await stack.board.createCard(repoID: stack.repo.id, title: "In flight").card
        card.column = .inProgress
        card.issueNumber = 102
        card.lastError = "implement-issue exited 1"
        try await stack.store.saveCard(card)

        let pr = pullRequest(number: 201, issue: 102, state: "OPEN")
        #expect(await watcher(for: stack).reconcile(card: card, against: [pr]))

        let after = try #require(try await stack.store.card(id: card.id))
        #expect(after.lastError == nil)
        #expect(after.prNumber == 201)
        #expect(after.prURL == "https://github.com/phmatray/Elliot/pull/201")
        #expect(after.branch == "feat/102-the-thing")
        #expect(after.column == .inReview)

        // The watcher *did* see this happen, so it is not a reconciliation.
        let audits = try await stack.store.audits(cardID: card.id)
        #expect(audits.first?.origin == .system(reason: .prBecameReady))
    }

    /// The watcher used to guard on `card.lastError == nil` before saying a
    /// pull request had been abandoned — so a card already carrying *any* other
    /// error never learned it, and went on showing a stale reason for ever.
    /// It acts whenever the text would change now, and only then.
    @Test("A card carrying another error still learns its pull request was abandoned")
    func watcherReplacesAStaleErrorWithTheClosedSentence() async throws {
        let stack = try await Stack.make(fixture: "create-issue-success.ndjson")
        defer { stack.cleanUp() }

        var card = try await stack.board.createCard(repoID: stack.repo.id, title: "Abandoned").card
        card.column = .inReview
        card.prNumber = 204
        card.lastError = "Checks are failing: build."
        try await stack.store.saveCard(card)

        let pr = pullRequest(number: 204, issue: 105, state: "CLOSED")
        let watcher = watcher(for: stack)

        #expect(await watcher.reconcile(card: card, against: [pr]))
        let first = try #require(try await stack.store.card(id: card.id))
        #expect(first.lastError == "The pull request was closed without being merged.")

        // Same card, same pull request: there is nothing left to say, so the
        // poll stops re-saving an identical row.
        #expect(await watcher.reconcile(card: first, against: [pr]) == false)
    }

    /// The one branch of the rewritten `reconcile` that still moves a card and
    /// that the two tests above do not reach. `GHPullRequest.verifiedOutcome`
    /// must read `MERGED` as `.merged` for this to work at all.
    @Test("A pull request merged outside Elliot sends the card to Done, as something the watcher saw")
    func watcherSendsAMergedCardToDone() async throws {
        let stack = try await Stack.make(fixture: "create-issue-success.ndjson")
        defer { stack.cleanUp() }

        var card = try await stack.board.createCard(repoID: stack.repo.id, title: "Landed").card
        card.column = .inReview
        card.prNumber = 205
        try await stack.store.saveCard(card)

        let pr = pullRequest(number: 205, issue: 106, state: "MERGED", mergedAt: Date())
        #expect(await watcher(for: stack).reconcile(card: card, against: [pr]))

        let after = try #require(try await stack.store.card(id: card.id))
        #expect(after.column == .done)

        let audits = try await stack.store.audits(cardID: card.id)
        #expect(audits.first?.origin == .system(reason: .prMergedExternally))
    }

    // MARK: - A pull request first seen already finished still names itself (#139)

    /// The case #139 exists for, and the one the common path hides: a card that
    /// holds only an **issue** number, whose pull request was opened *and*
    /// merged while Elliot was closed. It never sees a `.prOpen`, so the
    /// sighting that sends it to Done is its only chance to learn which pull
    /// request did it. Before #139 it landed in Done with all three fields nil
    /// — the board recording that the work finished but not what finished it.
    ///
    /// Matched by `PRMatcher` on the issue number, which is the branch of
    /// `reconcile` that `card.prNumber` being nil selects.
    @Test("A pull request first sighted already merged sends the card to Done naming itself")
    func watcherRecordsAPullRequestItOnlyEverSawMerged() async throws {
        let stack = try await Stack.make(fixture: "create-issue-success.ndjson")
        defer { stack.cleanUp() }

        var card = try await stack.board.createCard(repoID: stack.repo.id, title: "Landed unseen").card
        card.column = .inProgress
        card.issueNumber = 107
        card.prNumber = nil
        try await stack.store.saveCard(card)

        let pr = pullRequest(number: 206, issue: 107, state: "MERGED", mergedAt: Date())
        #expect(await watcher(for: stack).reconcile(card: card, against: [pr]))

        let after = try #require(try await stack.store.card(id: card.id))
        #expect(after.column == .done)
        // The whole point of the issue: Done *and* able to say what closed it.
        #expect(after.prNumber == 206)
        #expect(after.prURL == "https://github.com/phmatray/Elliot/pull/206")
        #expect(after.branch == "feat/107-the-thing")
    }

    /// The closed-unmerged twin. The fields must arrive *alongside* the banner,
    /// not instead of it — a card that says only "closed without being merged"
    /// with no pull request to open is the same dead end one case over.
    @Test("A pull request first sighted already closed records itself and says it was abandoned")
    func watcherRecordsAPullRequestItOnlyEverSawClosed() async throws {
        let stack = try await Stack.make(fixture: "create-issue-success.ndjson")
        defer { stack.cleanUp() }

        var card = try await stack.board.createCard(repoID: stack.repo.id, title: "Dropped unseen").card
        card.column = .inProgress
        card.issueNumber = 108
        card.prNumber = nil
        try await stack.store.saveCard(card)

        let pr = pullRequest(number: 207, issue: 108, state: "CLOSED")
        #expect(await watcher(for: stack).reconcile(card: card, against: [pr]))

        let after = try #require(try await stack.store.card(id: card.id))
        #expect(after.prNumber == 207)
        #expect(after.prURL == "https://github.com/phmatray/Elliot/pull/207")
        #expect(after.branch == "feat/108-the-thing")
        #expect(after.lastError == "The pull request was closed without being merged.")
    }

    /// The regression AC4 creates if `reconcile` keeps matching on the recorded
    /// number alone, found in review of #139.
    ///
    /// Writing the abandoned pull request's number onto a card that is *still
    /// in flight* ties the watcher to it: `reconcile` prefers an exact
    /// `card.prNumber` match over `PRMatcher`, so a replacement pull request
    /// for the same issue becomes invisible for ever and the card never leaves
    /// In Progress. Before #139 the number was never written, so this could not
    /// happen — the fix must not buy the panel a link at the cost of the card.
    ///
    /// Reachable in production: `tick()` reconciles `.inProgress` as well as
    /// `.inReview`.
    @Test("A card whose pull request was abandoned still finds the replacement for the same issue")
    func watcherFindsAReplacementAfterAnAbandonedPullRequest() async throws {
        let stack = try await Stack.make(fixture: "create-issue-success.ndjson")
        defer { stack.cleanUp() }

        var card = try await stack.board.createCard(repoID: stack.repo.id, title: "Second attempt").card
        card.column = .inProgress
        card.issueNumber = 109
        try await stack.store.saveCard(card)

        let watcher = watcher(for: stack)
        let abandoned = pullRequest(number: 208, issue: 109, state: "CLOSED")

        // First sighting: the card records what was abandoned, and stays put.
        #expect(await watcher.reconcile(card: card, against: [abandoned]))
        let afterFirst = try #require(try await stack.store.card(id: card.id))
        #expect(afterFirst.prNumber == 208)
        #expect(afterFirst.column == .inProgress)

        // Someone opens a new pull request for the same issue. The card must
        // see it, even though it now holds the dead one's number.
        let replacement = pullRequest(number: 209, issue: 109, state: "OPEN")
        #expect(await watcher.reconcile(card: afterFirst, against: [abandoned, replacement]))

        let afterSecond = try #require(try await stack.store.card(id: card.id))
        #expect(afterSecond.prNumber == 209)
        #expect(afterSecond.prURL == "https://github.com/phmatray/Elliot/pull/209")
        #expect(afterSecond.branch == "feat/109-the-thing")
        #expect(afterSecond.lastError == nil)
        #expect(afterSecond.column == .inReview)
    }

    /// The other half of the same rule: a card that has *reached Done* keeps
    /// the pull request it recorded. Nothing is in flight, so there is no
    /// replacement to look for, and re-matching by issue could pull the card
    /// onto an unrelated later pull request.
    @Test("A Done card keeps the pull request it recorded, and is not re-matched by issue")
    func doneCardKeepsItsRecordedPullRequest() async throws {
        let stack = try await Stack.make(fixture: "create-issue-success.ndjson")
        defer { stack.cleanUp() }

        var card = try await stack.board.createCard(repoID: stack.repo.id, title: "Finished").card
        card.column = .done
        card.issueNumber = 110
        card.prNumber = 210
        card.prURL = "https://github.com/phmatray/Elliot/pull/210"
        card.branch = "feat/110-the-thing"
        try await stack.store.saveCard(card)

        let recorded = pullRequest(number: 210, issue: 110, state: "CLOSED")
        let later = pullRequest(number: 211, issue: 110, state: "OPEN")

        // Nothing to say: it already carries 210's fields and the banner would
        // be the only change, so this is the no-op branch, not a re-match.
        _ = await watcher(for: stack).reconcile(card: card, against: [recorded, later])

        let after = try #require(try await stack.store.card(id: card.id))
        #expect(after.prNumber == 210)
        #expect(after.column == .done)
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

}  // extension EndToEndSuites
