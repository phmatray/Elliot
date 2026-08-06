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
