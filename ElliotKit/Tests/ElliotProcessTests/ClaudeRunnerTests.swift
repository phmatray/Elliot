import ElliotModel
import Foundation
import TestSupport
import Testing

@testable import ElliotProcess

/// The repository root, derived from this file's location so the tests find the
/// same `Scripts/` and `Fixtures/` a human would use from a terminal.
enum TestPaths {
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ElliotProcessTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // ElliotKit
        .deletingLastPathComponent()   // repo root

    static let fakeClaude = repoRoot.appendingPathComponent("Scripts/fake-claude.sh").path

    static func fixture(_ name: String) -> String {
        repoRoot.appendingPathComponent("Fixtures/stream-json/\(name)").path
    }

    static func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elliot-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private func config(environment extra: [String: String] = [:]) -> ToolConfig {
    var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    env.merge(extra) { _, new in new }
    return ToolConfig(
        claudePath: TestPaths.fakeClaude,
        ghPath: "/usr/bin/true",
        gitPath: "/usr/bin/true",
        environment: env
    )
}

@Suite("Claude invocation")
struct ClaudeInvocationTests {

    @Test("The argument list is exactly what the contract requires")
    func argumentList() {
        let runID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let invocation = ClaudeInvocation(
            runID: runID,
            prompt: "/ai-migration-kit:implement-issue 47",
            cwd: "/Users/philippe/repo/gh-phmatray/Elliot"
        )
        #expect(invocation.arguments() == [
            "-p", "/ai-migration-kit:implement-issue 47",
            "--output-format", "stream-json",
            "--verbose",
            "--permission-mode", "bypassPermissions",
            "--session-id", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            "--add-dir", "/Users/philippe/repo/gh-phmatray/Elliot",
        ])
    }

    @Test("The session id is lowercase, as the CLI's UUID validation expects")
    func sessionIDIsLowercased() {
        let invocation = ClaudeInvocation(runID: UUID(), prompt: "x", cwd: "/tmp")
        let args = invocation.arguments()
        let sessionID = args[args.firstIndex(of: "--session-id")! + 1]
        #expect(sessionID == sessionID.lowercased())
        #expect(UUID(uuidString: sessionID) != nil)
    }

    @Test("Allowed tools are comma-joined, and omitted when empty")
    func allowedTools() {
        var invocation = ClaudeInvocation(runID: UUID(), prompt: "x", cwd: "/tmp")
        #expect(!invocation.arguments().contains("--allowedTools"))

        invocation.extraAllowedTools = ["Bash(git status *)", "Read"]
        let args = invocation.arguments()
        #expect(args[args.firstIndex(of: "--allowedTools")! + 1] == "Bash(git status *),Read")
    }

    @Test("A per-run budget reaches the CLI, and is absent when there is no ceiling")
    func budgetFlag() {
        // The flag is the only thing that can stop a single runaway run: nothing
        // on our side can interrupt a turn in progress. If it silently stopped
        // reaching argv, the ceiling would look armed and be inert — which is
        // exactly the shape of the `gh secret list` trap.
        var invocation = ClaudeInvocation(runID: UUID(), prompt: "x", cwd: "/tmp")
        #expect(!invocation.arguments().contains("--max-budget-usd"))

        invocation.maxBudgetUSD = 2.5
        let args = invocation.arguments()
        #expect(args[args.firstIndex(of: "--max-budget-usd")! + 1] == "2.50")
    }

    @Test("The budget is formatted as money, never as scientific notation")
    func budgetIsNeverScientific() {
        // `"\(0.00001)"` is `"1e-05"`, which the CLI would reject or misread.
        // Interpolating the Double here would have been the obvious thing to do.
        var invocation = ClaudeInvocation(runID: UUID(), prompt: "x", cwd: "/tmp")
        for (value, expected) in [(0.000_01, "0.00"), (10.0, "10.00"), (1_000.5, "1000.50")] {
            invocation.maxBudgetUSD = value
            let args = invocation.arguments()
            let written = args[args.firstIndex(of: "--max-budget-usd")! + 1]
            #expect(written == expected)
            #expect(!written.contains("e"))
        }
    }

    @Test("Partial messages stay off unless asked for")
    func partialMessagesAreOptional() {
        var invocation = ClaudeInvocation(runID: UUID(), prompt: "x", cwd: "/tmp")
        #expect(!invocation.arguments().contains("--include-partial-messages"))
        invocation.includePartialMessages = true
        #expect(invocation.arguments().contains("--include-partial-messages"))
    }

    @Test("The permission mode comes from the repo's setting")
    func permissionModeIsPerRepo() {
        var invocation = ClaudeInvocation(runID: UUID(), prompt: "x", cwd: "/tmp")
        invocation.permissionMode = .acceptEdits
        let args = invocation.arguments()
        #expect(args[args.firstIndex(of: "--permission-mode")! + 1] == "acceptEdits")
    }
}

@Suite("Claude runner", .serialized)
struct ClaudeRunnerTests {

    /// Bounded, so a child that never dies fails its test in seconds instead of
    /// hanging `swift test` — and with it the SwiftPM build lock — forever.
    private func collect(
        _ run: ClaudeRun, timeout: Duration = .seconds(10)
    ) async throws -> (events: [StreamEvent], outcome: ClaudeRunOutcome?) {
        try await withTimeout(timeout) {
            var events: [StreamEvent] = []
            var outcome: ClaudeRunOutcome?
            for await update in run.updates {
                switch update {
                case .event(let event): events.append(event)
                case .finished(let result): outcome = result
                case .started, .stalled: break
                }
            }
            return (events, outcome)
        }
    }

    @Test("A successful run streams its events and reports a clean result")
    func successfulRun() async throws {
        let dir = try TestPaths.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("run.ndjson")

        let run = try ClaudeRun.start(
            invocation: ClaudeInvocation(
                runID: UUID(), prompt: "/ai-migration-kit:create-issue something", cwd: dir.path
            ),
            config: config(environment: [
                "FAKE_CLAUDE_FIXTURE": TestPaths.fixture("create-issue-success.ndjson"),
            ]),
            logURL: logURL
        )
        defer { run.cancel() }
        let (events, outcome) = try await collect(run)

        // init + 4 message events + text + result
        #expect(events.count == 8)
        guard case .systemInit(let info) = events.first else {
            Issue.record("expected the first event to be init")
            return
        }
        #expect(info.slashCommands.contains("ai-migration-kit:create-issue"))

        let result = try #require(outcome?.result)
        #expect(result.isClean)
        #expect(result.totalCostUSD == 0.1834)
        #expect(outcome?.exitCode == 0)

        // The raw log is written verbatim, every line of it.
        let log = try String(contentsOf: logURL, encoding: .utf8)
        #expect(log.split(separator: "\n").count == 8)
    }

    @Test("Four thousand events reach the caller and the log, terminal one included")
    func aLargeRunLosesNothing() async throws {
        // Volume coverage of the decode path, and **not** a race detector —
        // stated plainly because it was written as one and measurement said
        // otherwise. With #26's historical drain defect reintroduced, the direct
        // probe in `StreamingProcessDrainTests` failed 60 times out of 60 while
        // this test passed. The reason is structural: the burst is followed by
        // the fixture's own eight lines, and replaying those through the shell
        // takes long enough for the reader to empty the pipe, so nothing is left
        // in flight at exit and there is no window to lose anything in. Any
        // shape that *would* contend has to put the burst last, which is exactly
        // where the terminal event has to be.
        //
        // What it does hold is worth holding: `successfulRun` next door proves
        // eight lines survive, and this proves four thousand do — through the
        // log mirror — so a buffering bug that only appears past one chunk
        // cannot hide behind a small fixture.
        let burst = 4_000

        for iteration in 1...5 {
            let dir = try TestPaths.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let logURL = dir.appendingPathComponent("run.ndjson")

            let run = try ClaudeRun.start(
                invocation: ClaudeInvocation(runID: UUID(), prompt: "x", cwd: dir.path),
                config: config(environment: [
                    "FAKE_CLAUDE_FIXTURE": TestPaths.fixture("create-issue-success.ndjson"),
                    "FAKE_CLAUDE_BURST": "\(burst)",
                ]),
                logURL: logURL
            )
            defer { run.cancel() }
            let (events, outcome) = try await collect(run, timeout: .seconds(60))

            let result = try #require(outcome?.result, "iteration \(iteration) lost the terminal event")
            #expect(result.isClean, "iteration \(iteration)")
            #expect(result.totalCostUSD == 0.1834, "iteration \(iteration)")
            #expect(outcome?.exitCode == 0, "iteration \(iteration)")

            // The **log** is the lossless record, and it must hold every line.
            let log = try String(contentsOf: logURL, encoding: .utf8)
            #expect(log.split(separator: "\n").count == burst + 8, "iteration \(iteration)")

            // `updates` is not lossless and must not be asserted as though it
            // were. It is `AsyncStream(bufferingPolicy: .bufferingNewest(512))`
            // — deliberately bounded, so a consumer that falls behind drops the
            // oldest rather than growing without limit or applying backpressure
            // to the run. An earlier version of this test asserted
            // `events.count == burst + 8` and passed only because the consumer
            // usually keeps up; under a full parallel `swift test` it does not,
            // and it failed having received 3 985 of 4 008. That was a defect in
            // the test, not in the runner.
            //
            // What the bound guarantees is the thing worth asserting: the
            // terminal event is the *newest*, so it is never the one dropped —
            // `#require(outcome?.result)` above is that assertion. And the raw
            // bytes reach the log before anything is parsed, which is why the
            // count that must be exact is the log's.
            // Only the bound that cannot depend on scheduling. A lower bound on
            // how many events *arrived* would be the same defect again, one
            // number further down: it would pass on an idle machine and fail on
            // a busy one, which is what "flaky" means.
            #expect(events.count <= burst + 8, "iteration \(iteration): more events than lines")
        }
    }

    @Test("A run refused a tool is reported as not clean, despite exiting zero")
    func runWithDenials() async throws {
        let dir = try TestPaths.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let run = try ClaudeRun.start(
            invocation: ClaudeInvocation(runID: UUID(), prompt: "x", cwd: dir.path),
            config: config(environment: ["FAKE_CLAUDE_FIXTURE": TestPaths.fixture("denied.ndjson")]),
            logURL: dir.appendingPathComponent("run.ndjson")
        )
        defer { run.cancel() }
        let (_, outcome) = try await collect(run)

        let result = try #require(outcome?.result)
        #expect(outcome?.exitCode == 0)
        #expect(!result.isError)
        #expect(!result.isClean)
        #expect(result.permissionDenials.map(\.toolName) == ["Bash"])
    }

    @Test("A final line with no trailing newline is not lost")
    func noTrailingNewline() async throws {
        let dir = try TestPaths.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let run = try ClaudeRun.start(
            invocation: ClaudeInvocation(runID: UUID(), prompt: "x", cwd: dir.path),
            config: config(environment: [
                "FAKE_CLAUDE_FIXTURE": TestPaths.fixture("no-trailing-newline.ndjson"),
            ]),
            logURL: dir.appendingPathComponent("run.ndjson")
        )
        defer { run.cancel() }
        let (events, outcome) = try await collect(run)

        #expect(events.count == 1)
        #expect(outcome?.result?.text == "no trailing newline")
    }

    @Test("Events arrive incrementally rather than all at the end")
    func eventsStreamLive() async throws {
        let dir = try TestPaths.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let run = try ClaudeRun.start(
            invocation: ClaudeInvocation(runID: UUID(), prompt: "x", cwd: dir.path),
            config: config(environment: [
                "FAKE_CLAUDE_FIXTURE": TestPaths.fixture("create-issue-success.ndjson"),
                "FAKE_CLAUDE_DELAY_MS": "40",
            ]),
            logURL: dir.appendingPathComponent("run.ndjson")
        )

        defer { run.cancel() }

        // Returned rather than captured: `withTimeout`'s operation is
        // `@Sendable`, so mutating locals from inside it is a Swift 6 error.
        let (sawEventBeforeFinish, finished) = try await withTimeout(.seconds(10)) {
            () -> (Bool, Bool) in
            var sawEvent = false
            var didFinish = false
            for await update in run.updates {
                switch update {
                case .event where !didFinish: sawEvent = true
                case .finished: didFinish = true
                default: break
                }
            }
            return (sawEvent, didFinish)
        }
        // The point of the test: events are delivered as they arrive, not batched
        // after the process exits. No clock, so no contention flake.
        #expect(sawEventBeforeFinish)
        #expect(finished)
    }

    /// One line, many events — live.
    ///
    /// An assistant turn can carry prose *and* one or more tool calls in the
    /// same `message.content` array. `StreamEventDecoder.decode` is
    /// `decodeAll(…).first`, so while the runner used it the tail returned the
    /// prose and dropped every tool call that shared the turn with it. The log
    /// on disk is read back through `decodeAll`, so the same run read one way
    /// while it was going and another once it had finished — nothing failed,
    /// the two simply disagreed.
    ///
    /// Asserted on the events seen **before** `.finished`, because "the log
    /// ends up complete" was already true of the broken version.
    @Test("A turn carrying prose and tool calls streams all of them, live")
    func oneTurnStreamsEveryBlockLive() async throws {
        let dir = try TestPaths.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ready = dir.appendingPathComponent("ready")
        let logURL = dir.appendingPathComponent("run.ndjson")

        let run = try ClaudeRun.start(
            invocation: ClaudeInvocation(runID: UUID(), prompt: "x", cwd: dir.path),
            config: config(environment: [
                "FAKE_CLAUDE_FIXTURE": TestPaths.fixture("interleaved-tools.ndjson"),
                // Spaced out so the lines cannot all land in one read and be
                // indistinguishable from a batch delivered at the end.
                "FAKE_CLAUDE_DELAY_MS": "20",
                "FAKE_CLAUDE_READY": ready.path,
            ]),
            logURL: logURL
        )
        defer { run.cancel() }

        // Wait on the fact that the child is up, not on a duration: under load a
        // fixed sleep is either a flake or dead time, and the harness touches
        // this file for exactly this reason.
        try await withTimeout(.seconds(5)) {
            while !FileManager.default.fileExists(atPath: ready.path) {
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        // Returned rather than captured: `withTimeout`'s operation is
        // `@Sendable`, so mutating locals from inside it is a Swift 6 error.
        let live = try await withTimeout(.seconds(10)) { () -> [StreamEvent] in
            var beforeFinish: [StreamEvent] = []
            var didFinish = false
            for await update in run.updates {
                switch update {
                case .event(let event) where !didFinish: beforeFinish.append(event)
                case .finished: didFinish = true
                default: break
                }
            }
            return beforeFinish
        }

        // The fixture's second line is the whole point: text + two tool calls in
        // one turn. Under `decode` this arrived as the text alone.
        #expect(live[1] == .assistantText("Reading both files at once."))
        #expect(live[2] == .assistantToolUse(
            name: "Read", id: "tu_a", inputPreview: #"{"file_path":"\/repo\/A.swift"}"#
        ))
        #expect(live[3] == .assistantToolUse(
            name: "Read", id: "tu_b", inputPreview: #"{"file_path":"\/repo\/B.swift"}"#
        ))

        // Six lines, eight events. Stated as an inequality as well as a count
        // because "one event per line" is exactly the assumption that was wrong:
        // a run whose events merely equalled its lines would pass a count and
        // still be dropping blocks.
        let logged = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n").count
        #expect(logged == 6)
        #expect(live.count == 8)
        #expect(live.count > logged)

        // And the live stream says exactly what the file says, which is the
        // disagreement this closes.
        let fromDisk = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
            .flatMap { StreamEventDecoder.decodeAll(line: Data($0.utf8)) }
        #expect(live == fromDisk)
    }

    @Test("Cancelling terminates the child and reports it")
    func cancellation() async throws {
        let dir = try TestPaths.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ready = dir.appendingPathComponent("ready")
        let run = try ClaudeRun.start(
            invocation: ClaudeInvocation(runID: UUID(), prompt: "x", cwd: dir.path),
            config: config(environment: [
                "FAKE_CLAUDE_MODE": "trap",
                "FAKE_CLAUDE_READY": ready.path,
            ]),
            logURL: dir.appendingPathComponent("run.ndjson")
        )
        defer { run.cancel() }

        // Wait on the fact that the trap is installed, not on a duration: 143 is
        // only produced once the child is trap-protected, and under load a fixed
        // sleep can expire before bash gets there.
        try await withTimeout(.seconds(5)) {
            while !FileManager.default.fileExists(atPath: ready.path) {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        run.cancel()

        let (_, outcome) = try await collect(run)
        let result = try #require(outcome)
        #expect(result.wasTerminated)
        #expect(result.wasSignalled)
        // Claude Code documents 143 for its own SIGTERM shutdown; the fake
        // reproduces that so the runner is exercised against the real contract.
        #expect(result.exitCode == 143)
    }

    @Test("A hanging child is still reaped, and readiness is observable")
    func hangingChildIsReaped() async throws {
        let dir = try TestPaths.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ready = dir.appendingPathComponent("ready")

        let run = try ClaudeRun.start(
            invocation: ClaudeInvocation(runID: UUID(), prompt: "x", cwd: dir.path),
            config: config(environment: [
                "FAKE_CLAUDE_MODE": "hang",
                "FAKE_CLAUDE_READY": ready.path,
            ]),
            logURL: dir.appendingPathComponent("run.ndjson")
        )
        defer { run.cancel() }

        try await withTimeout(.seconds(5)) {
            while !FileManager.default.fileExists(atPath: ready.path) {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        run.cancel()

        let outcome = try await withTimeout(.seconds(5)) { () -> ClaudeRunOutcome? in
            var last: ClaudeRunOutcome?
            for await update in run.updates {
                if case .finished(let result) = update { last = result }
            }
            return last
        }
        #expect(try #require(outcome).wasTerminated)
    }

    @Test("A crashing run surfaces its stderr")
    func crashingRun() async throws {
        let dir = try TestPaths.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let run = try ClaudeRun.start(
            invocation: ClaudeInvocation(runID: UUID(), prompt: "x", cwd: dir.path),
            config: config(environment: ["FAKE_CLAUDE_MODE": "crash", "FAKE_CLAUDE_EXIT": "9"]),
            logURL: dir.appendingPathComponent("run.ndjson")
        )
        defer { run.cancel() }
        let (_, outcome) = try await collect(run)
        #expect(outcome?.exitCode == 9)
        #expect(outcome?.result == nil)
        #expect(outcome?.stderr.contains("simulated failure") == true)
    }

    @Test("The exact command line is what the contract says it should be")
    func argvIsExact() async throws {
        let dir = try TestPaths.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let argvOut = dir.appendingPathComponent("argv.txt")
        let runID = UUID()

        let run = try ClaudeRun.start(
            invocation: ClaudeInvocation(
                runID: runID, prompt: "/ai-migration-kit:implement-issue 47", cwd: dir.path
            ),
            config: config(environment: ["FAKE_CLAUDE_ARGV_OUT": argvOut.path]),
            logURL: dir.appendingPathComponent("run.ndjson")
        )
        defer { run.cancel() }
        _ = try await collect(run)

        let argv = try String(contentsOf: argvOut, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast()
            .map(String.init)
        #expect(argv == [
            "-p", "/ai-migration-kit:implement-issue 47",
            "--output-format", "stream-json",
            "--verbose",
            "--permission-mode", "bypassPermissions",
            "--session-id", runID.uuidString.lowercased(),
            "--add-dir", dir.path,
        ])
    }

    /// The labels a card asked for, followed all the way to the argv the child
    /// process is actually handed.
    ///
    /// Every other test of this feature stops at a `String` — the builder's
    /// output, the rule engine's action, the store's column. This is the only
    /// one that runs a real `Process` and reads back what it received, which is
    /// the last step where quoting can still be got wrong: `-p` is one argv
    /// element, so a shell-quoting mistake would show up here and nowhere else.
    ///
    /// ⚠️ What it does **not** establish is whether `create-issue` acts on the
    /// flag. That is the skill's business, it is measured in this pull request's
    /// description, and no test in this repository can answer it.
    @Test("A card's labels reach the child process, in one argv element")
    func labelsReachTheArgv() async throws {
        let dir = try TestPaths.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let argvOut = dir.appendingPathComponent("argv.txt")
        let then = Date(timeIntervalSince1970: 1_700_000_000)

        // Through the real rule engine, from a real card — not a hand-written
        // prompt string, which would prove only that this test can type.
        let card = Card(
            repoID: UUID(), title: "Bound the await", body: "It hangs.",
            labels: ["bug", "documentation"],
            columnEnteredAt: then, createdAt: then, updatedAt: then
        )
        let outcome = evaluateMove(
            from: .backlog, to: .todo, card: card,
            context: MoveContext(
                repoIsEnabled: true, activeRunID: nil, allowSideEffects: true,
                // A human's move, and backlog → todo besides: the green guard has
                // nothing to say about filing an issue, and there is no pull
                // request for it to have read.
                requiresVerifiedGreen: false, prVerdict: nil
            )
        )
        guard case .action(let action) = outcome else {
            Issue.record("the move produced no action: \(outcome)")
            return
        }
        let prompt = SlashCommandBuilder.prompt(for: action)

        let run = try ClaudeRun.start(
            invocation: ClaudeInvocation(runID: UUID(), prompt: prompt, cwd: dir.path),
            config: config(environment: ["FAKE_CLAUDE_ARGV_OUT": argvOut.path]),
            logURL: dir.appendingPathComponent("run.ndjson")
        )
        defer { run.cancel() }
        _ = try await collect(run)

        let argv = try String(contentsOf: argvOut, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast()
            .map(String.init)

        // The idea is `Card.ideaText`, which joins a note card's title and body
        // — the flags follow all of it, never interrupt it.
        let flag = try #require(argv.firstIndex(of: "-p").map { argv[$0 + 1] })
        let expected = #"""
            /ai-migration-kit:create-issue Bound the await. It hangs. --label "bug" --label "documentation"
            """#
        #expect(flag == expected)
        // One element, not three: the quotes are payload, and a child that
        // received them as separate arguments would be a builder emitting shell
        // syntax into an argv that never sees a shell.
        #expect(!argv.contains(#"--label"#))
    }

    /// The stream and the durable log must agree, however the run is timed.
    ///
    /// A child that writes its whole output and exits at once catches a
    /// readability handler mid-flight, which used to yield those lines into an
    /// already-finished stream: the log held all eight events and the card
    /// showed none. Many at once because a single run hits that window only
    /// occasionally — this is a race, and the assertion is what is exact, not
    /// the reproduction.
    @Test("Every line in the log also reaches the stream")
    func streamAgreesWithTheLog() async throws {
        let dir = try TestPaths.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Sustained rather than one big burst: the window opens when a child
        // exits while a handler is mid-read, and that needs the machine busy
        // spawning and reaping, not merely many runs started at once.
        for round in 0..<8 {
            await withTaskGroup(of: Void.self) { group in
                for i in (round * 16)..<(round * 16 + 16) {
                    group.addTask {
                        let logURL = dir.appendingPathComponent("run-\(i).ndjson")
                        guard let run = try? ClaudeRun.start(
                            invocation: ClaudeInvocation(runID: UUID(), prompt: "x", cwd: dir.path),
                            config: config(environment: [
                                "FAKE_CLAUDE_FIXTURE": TestPaths.fixture("create-issue-success.ndjson"),
                            ]),
                            logURL: logURL
                        ) else {
                            Issue.record("run \(i) did not start")
                            return
                        }
                        var events = 0
                        for await update in run.updates {
                            if case .event = update { events += 1 }
                        }
                        let logged = ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "")
                            .split(separator: "\n").count
                        #expect(logged == 8, "run \(i) logged \(logged) lines")
                        #expect(events == logged, "run \(i) streamed \(events) of \(logged) lines")
                    }
                }
            }
        }
    }

    @Test("The runner refuses a claude path that is not executable")
    func missingBinary() throws {
        let dir = try TestPaths.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var brokenConfig = config()
        brokenConfig.claudePath = "/nonexistent/claude"

        #expect(throws: ProcessError.self) {
            _ = try ClaudeRun.start(
                invocation: ClaudeInvocation(runID: UUID(), prompt: "x", cwd: dir.path),
                config: brokenConfig,
                logURL: dir.appendingPathComponent("run.ndjson")
            )
        }
    }
}
