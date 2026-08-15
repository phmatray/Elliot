import ACP
import ACPModel
import ElliotModel
import Foundation
import Testing
import TestSupport

@testable import ElliotProcess

/// One live turn, end to end: a real child, a real handshake, a real prompt, real notifications,
/// and the run log written under the drain lock — with `Scripts/fake-acp.py` standing in for the
/// adapter so the suite stays deterministic and needs no network, no tokens and no GitHub.
@Suite("ACP runner")
struct ACPRunnerTests {
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ElliotProcessTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // ElliotKit
            .deletingLastPathComponent()  // repository root
    }

    /// The same `ACPAgentProcess` shape `ACPSessionTests.agent(mode:)` builds.
    static func agent(
        mode: String = "ok",
        fixture: String = "fake-simple-turn.json",
        environment extra: [String: String] = [:]
    ) -> ACPAgentProcess {
        var environment = [
            "FAKE_ACP_MODE": mode,
            "FAKE_ACP_FIXTURE": repositoryRoot
                .appendingPathComponent("Fixtures/acp/\(fixture)").path,
        ]
        for (key, value) in extra { environment[key] = value }
        return ACPAgentProcess(
            executable: "/usr/bin/python3",
            arguments: [repositoryRoot.appendingPathComponent("Scripts/fake-acp.py").path],
            cwd: "/tmp",
            environment: environment
        )
    }

    static func invocation(
        cwd: String = "/tmp",
        permissionMode: PermissionMode = .bypassPermissions,
        extraAllowedTools: [String] = []
    ) -> AgentInvocation {
        AgentInvocation(
            runID: UUID(),
            prompt: "go",
            cwd: cwd,
            permissionMode: permissionMode,
            extraAllowedTools: extraAllowedTools,
            extraDirectories: [],
            maxBudgetUSD: nil,
            resumeFromAgentSession: nil
        )
    }

    /// A scratch `.jsonl` inside the one shared `ELLIOT_HOME`.
    static func logURL(_ label: String) throws -> URL {
        let home = TestHome.scratch(label)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home.appendingPathComponent("\(UUID().uuidString).jsonl")
    }

    /// Every non-empty line of a run log, decoded as one JSON object each.
    ///
    /// `[:]` for a line that parses to something other than an object, so the "one whole JSON
    /// object per line" assertion below sees a failure rather than a thrown test.
    static func objects(inLogAt url: URL) throws -> [[String: Any]] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.isEmpty }
            .map {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] ?? [:]
            }
    }

    /// Drains a run to completion, keeping the events it streamed.
    ///
    /// The stream is `bufferingNewest(512)` and **deliberately lossy** — nothing here may assert a
    /// count on what comes back. What it is good for is existence (`contains`), which is what the
    /// tests below ask of it; counts are asserted against the log, which is lossless.
    static func drain(_ run: AgentRun) async -> (events: [RunEvent], outcome: AgentRunOutcome?) {
        var events: [RunEvent] = []
        var outcome: AgentRunOutcome?
        for await update in run.updates {
            switch update {
            case .event(let event): events.append(event)
            case .finished(let finished): outcome = finished
            case .started, .stalled, .resumed: break
            }
        }
        return (events, outcome)
    }

    /// Drains a run keeping **only** the silence notices, in the order they arrived.
    ///
    /// The counterpart of `drain`, which swallows exactly these two cases — a separate collector
    /// rather than a flag on that one, because everything else in this suite asserts on the log
    /// and nothing else here has any use for `.stalled`/`.resumed`. `ClaudeRunnerTests`
    /// (`collectSilences`) states the same shape one runner over; the two are the same eight lines
    /// because they are one question asked of two enums, and this one outlives the other when
    /// Task 18 deletes `ClaudeRunner.swift`.
    static func silences(_ run: AgentRun, timeout: Duration = .seconds(30)) async throws
        -> [RunSilence]
    {
        try await withTimeout(timeout) {
            var notices: [RunSilence] = []
            for await update in run.updates {
                switch update {
                case .stalled: notices.append(.wentQuiet)
                case .resumed: notices.append(.startedTalkingAgain)
                case .started, .event, .finished: break
                }
            }
            return notices
        }
    }

    @Test("a turn streams its events and writes every raw line to the log")
    func aTurnStreamsAndLogs() async throws {
        let logURL = try Self.logURL("acp-runner")
        let run = try AgentRun.start(
            invocation: Self.invocation(), agent: Self.agent(), logURL: logURL)
        // Armed for the reason `armKiller`'s doc comment gives: every `Client` request this run
        // makes reaches `sendRequest(…, timeout: nil)`, which no `withTimeout` can bound, so a
        // regression would hang `swift test` rather than fail it.
        let (killer, killerFired) = armKiller { run.session.transport.terminate() }
        defer { killer.cancel() }

        let (events, outcome) = await Self.drain(run)

        // ⛔ Asserted on the LOG, never on `updates`: the stream is `bufferingNewest(512)` and
        // deliberately lossy, and the identical assertion on a stream failed 9/10 against 0/10 on
        // the file (#128).
        let objects = try Self.objects(inLogAt: logURL)

        // ⚠️ The mirror is on `receiveStdout`, so the log holds what the ADAPTER SENT plus Elliot's
        // own two records — never Elliot's requests, which go to stdin. So `initialize` and
        // `session/new` do not appear; their *responses* do, and a response carries `id`, not
        // `method`. Asserting a bare `>=` count would see neither a missing line nor a duplicated
        // one, so assert the shape instead: every line parses, and the methods present are exactly
        // the expected set.
        #expect(objects.allSatisfy { !$0.isEmpty })  // one whole JSON object per line
        let methods = objects.compactMap { $0["method"] as? String }
        let responses = objects.filter { $0["method"] == nil && $0["id"] != nil }
        #expect(responses.count == 4)  // initialize, session/new, set_config_option, prompt
        // ⚠️ EIGHT, not the seven the plan's snippet asserted. The double emits a
        // `current_mode_update` of its own while answering `session/set_config_option`
        // (`Scripts/fake-acp.py`), on top of the fixture's seven frames — which is exactly what
        // `ACPSessionTests.fullTurn` already collects and comments as "1 mode + 7 fixture frames".
        #expect(methods.filter { $0 == "session/update" }.count == 8)
        #expect(methods.first == AgentLog.sessionMethod)
        #expect(methods.last == AgentLog.terminalMethod)
        #expect(events.contains { if case .session = $0 { true } else { false } })
        #expect(events.contains { if case .agentText = $0 { true } else { false } })

        // The turn ended on the adapter's own word, and the summary reached the caller as well as
        // the file.
        #expect(outcome?.summary?.stopReason == "end_turn")
        #expect(outcome?.agentSessionID == "sess-fake-0001")

        // ⛔ These three are what the consumer barrier in `AgentRun.start` buys, and they are the
        // reason the terminal line is assembled after it rather than on the prompt response. Every
        // one of them is folded by the notification consumer — a separate task — and the fixture's
        // `usage_update` is the frame immediately BEFORE the reply, so assembling at the response
        // reads whatever that task happened to have drained. Break-tested by assembling the
        // summary on the response instead: `usage?.used` and `usage?.costUSD` both came back
        // **nil on 5 of 5 runs**. `text` survived all five, which is the point rather than a
        // consolation — the same defect is loud in one field and silent in another, and only the
        // loud one would ever have been noticed.
        #expect(outcome?.summary?.text == "Reading the file.")
        #expect(outcome?.summary?.usage?.used == 37355)
        #expect(outcome?.summary?.usage?.costUSD == 0.2855775)

        // And the file says the same thing the caller was handed — the whole point of writing it.
        // Break-tested by closing the writer before the terminal record is written, which is the
        // race `AgentRun`'s one-close rule exists to lose: `methods.last` came back
        // `"session/update"` and the params `#require` went red, i.e. exactly the state in which
        // `AgentLog.lastSummary` answers nil with nothing anywhere saying why.
        let terminal = try #require(objects.last)
        let params = try #require(terminal["params"] as? [String: Any])
        #expect(params["stopReason"] as? String == "end_turn")
        #expect(params["text"] as? String == "Reading the file.")

        // Proof, not prose, that `killer` did not fire — see `armKiller`'s doc comment for why the
        // flag rather than `transport.isConnected` is the check.
        killer.cancel()
        await killer.value
        #expect(!killerFired.value)
    }

    /// Decision 5's invariant, under the condition that can break it. Drives the writer with
    /// chunks that end mid-frame while `record` is called between them, and asserts every line
    /// still parses. Without the pending-tail writer the two writers interleave and two lines come
    /// back unparseable.
    ///
    /// A unit test rather than a driven turn on purpose: the interleaving is a **timing**
    /// condition — `elliot/session` is written while the adapter is mid-stream — and a test that
    /// waited for the race to happen would be the kind that passes for the wrong reason.
    ///
    /// Break-tested by making `mirror` write the whole chunk: two of the three lines came back
    /// unparseable (`[nil, nil, "elliot/terminal"]`). ⚠️ Note which assertion did **not** catch
    /// it — `objects.count == 3` still passed, because a split frame is still two lines. Counting
    /// lines is not reading them.
    @Test("an Elliot record written mid-chunk does not split an adapter frame")
    func recordsLandOnLineBoundaries() throws {
        let url = try Self.logURL("acp-writer")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let writer = AgentLog.Writer(try FileHandle(forWritingTo: url))

        // One JSON-RPC frame, split so the first chunk ends **inside** it.
        let frame = #"{"jsonrpc":"2.0","method":"session/update","params":{"n":1}}"# + "\n"
        let split = frame.index(frame.startIndex, offsetBy: 30)
        writer.mirror(Data(frame[..<split].utf8))
        // The record lands between the two halves — the moment the file must still end on a
        // boundary.
        writer.record(AgentLog.sessionLine(
            RunSessionInfo(agentSessionID: "s", cwd: "/tmp", mode: "bypassPermissions")))
        writer.mirror(Data(frame[split...].utf8))
        writer.record(AgentLog.terminalLine(TurnSummary(stopReason: "end_turn", isError: false)))
        writer.close()

        let objects = try Self.objects(inLogAt: url)
        #expect(objects.count == 3)
        #expect(objects.allSatisfy { !$0.isEmpty })
        // The held half-frame is written intact once its own newline arrives, so it lands AFTER
        // the record that overtook it — nothing is lost and every line is whole, which is the
        // whole of the claim.
        #expect(objects.map { $0["method"] as? String }
            == [AgentLog.sessionMethod, "session/update", AgentLog.terminalMethod])
    }

    /// A `session/update` carrying a `sessionUpdate` string this build has never heard of.
    /// `ACPModel.SessionUpdate.init(from:)` **throws** on it, so without a `do`/`catch` in the
    /// consumer the line is dropped and `RunEvent.unreadable` is dead code.
    ///
    /// Break-tested by replacing the `catch`'s body with `events = []`: both assertions on the
    /// degraded row went red, and the two `agent_message_chunk` frames either side of it kept
    /// arriving — which is exactly the shape of the silent loss, a stream that looks healthy
    /// while one frame has gone.
    @Test("a frame this build cannot decode becomes one unreadable row, not a dropped line")
    func anUnknownFrameDegradesToOneRow() async throws {
        let logURL = try Self.logURL("acp-unknown")
        let run = try AgentRun.start(
            invocation: Self.invocation(),
            agent: Self.agent(fixture: "unknown-frame.json"),
            logURL: logURL
        )
        let (killer, killerFired) = armKiller { run.session.transport.terminate() }
        defer { killer.cancel() }

        let (events, _) = await Self.drain(run)

        let reasons = events.compactMap { event -> String? in
            if case .unreadable(_, let error) = event { return error }
            return nil
        }
        #expect(reasons.contains { $0.contains("quantum_entanglement_update") })
        // The consumer kept going: the frame AFTER the undecodable one still produced its event.
        // That is the claim — one degraded row, not a stream that stopped.
        #expect(events.contains {
            if case .agentText(let text) = $0 { text == "after the strange one" } else { false }
        })
        // And the raw bytes are kept rather than thrown away, so the line can be read by hand.
        let raws = events.compactMap { event -> Data? in
            if case .unreadable(let raw, _) = event { return raw }
            return nil
        }
        #expect(raws.contains { String(decoding: $0, as: UTF8.self).contains("spookiness") })

        killer.cancel()
        await killer.value
        #expect(!killerFired.value)
    }

    @Test("the first thing the log says is what the handshake established")
    func theLogIsSelfDescribing() async throws {
        let logURL = try Self.logURL("acp-selfdescribing")
        let run = try AgentRun.start(
            invocation: Self.invocation(cwd: "/tmp"), agent: Self.agent(), logURL: logURL)
        let (killer, killerFired) = armKiller { run.session.transport.terminate() }
        defer { killer.cancel() }

        _ = await Self.drain(run)

        let objects = try Self.objects(inLogAt: logURL)
        let line = try #require(objects.first { $0["method"] as? String == AgentLog.sessionMethod })
        let params = try #require(line["params"] as? [String: Any])
        #expect(params["cwd"] as? String == "/tmp")
        #expect(params["mode"] as? String == "bypassPermissions")
        #expect(params["agentSessionID"] as? String == "sess-fake-0001")
        #expect(params["agentName"] as? String == "fake-acp")
        #expect(params["agentVersion"] as? String == "0.0.1")
        // ⛔ The sixth field, and the only one that exercises a branch rather than a copy.
        // `AgentRun.model(in:)` prefers `NewSessionResponse.models?.currentModelId` and falls back
        // to the `configOptions` entry with id `model` — because the real adapter sends **no**
        // `models` at `session/new` and carries the model in `configOptions` instead
        // (`Fixtures/acp/session-new-commands.json`, the 0.66.0 recording the double's literals are
        // copied from). The double reproduces exactly that, so this assertion can only pass through
        // the fallback. Without it the whole function is dead weight the suite cannot see: measured
        // by inserting `if true { return nil }` as its first statement — the entire suite stayed
        // green — and again after this line existed, which failed here by name. A later
        // "simplification" to just `response.models?.currentModelId` would otherwise empty `model`
        // from the first line of every run log in silence.
        #expect(params["model"] as? String == "opus[1m]")

        killer.cancel()
        await killer.value
        #expect(!killerFired.value)
    }

    /// The whole silence path, against a real child — the mirror's `sawOutput`, the idle poll's
    /// `tick`, and both `AgentUpdate.announcing` sites.
    ///
    /// ⛔ **Without this test that path is unreachable from the suite and could be deleted
    /// outright without a single failure.** Two independent reasons, both measured: no other call
    /// site anywhere passes `idleTimeout:`, so `IdleWatch.tick` was only ever asked about a
    /// twenty-minute window inside a four-second suite; and `drain` — the sole consumer of
    /// `run.updates` — discards `.stalled` and `.resumed` (`case .started, .stalled, .resumed:
    /// break`). That matters more here than it reads: `RunSilence`'s own doc comment gives the
    /// reason, which is that there is deliberately no wall-clock kill, so silence is the *only*
    /// signal a wedged run gives, and a notice that is never withdrawn makes the signal mean
    /// nothing. `ClaudeRun`'s equivalent has been pinned since #309; this runner is its successor
    /// and inherited the wiring without the test.
    ///
    /// ⛔ Nothing here measures a duration. The double's own pace makes the silences
    /// (`FAKE_ACP_DELAY_MS` pauses before every line it writes, so a twelve-message conversation
    /// gives eleven gaps, each followed by more output), the window is short so the watchdog polls
    /// inside them — `min(idleTimeout, .seconds(30))` is what makes a twenty-millisecond window
    /// polled at twenty milliseconds rather than thirty seconds — and every assertion is about the
    /// *order* of what arrived.
    ///
    /// Break-tested three ways, one per piece of wiring, each on a committed tree:
    /// 1. the mirror's announcement dropped, keeping the `sawOutput` call — **12 `.wentQuiet` in a
    ///    row and not one withdrawal**, which is #309's defect verbatim, red on `contains` and on
    ///    `alternates`;
    /// 2. the whole `idleTask` replaced by `Task {}` — no notices at all, red on three;
    /// 3. `min(idleTimeout, .seconds(30))` replaced by a flat thirty seconds — also no notices,
    ///    red on the same three. That third one is worth its line: the clamp is a claim its own
    ///    comment makes ("stops a shorter window being announced up to thirty seconds after it was
    ///    crossed") and no test could see it, so a tidy-up removing it would have left a watchdog
    ///    that is *present, correct and useless* on every window shorter than its poll.
    @Test("a run that goes quiet and talks again announces both, alternating")
    func silenceAndRecoveryAlternate() async throws {
        let logURL = try Self.logURL("acp-silence")
        let run = try AgentRun.start(
            invocation: Self.invocation(),
            agent: Self.agent(environment: ["FAKE_ACP_DELAY_MS": "60"]),
            logURL: logURL,
            idleTimeout: .milliseconds(20)
        )
        let (killer, killerFired) = armKiller { run.session.transport.terminate() }
        defer { killer.cancel() }

        let notices = try await Self.silences(run)

        #expect(!notices.isEmpty, "the watchdog never looked inside a gap")
        // The half that a latch set in one place and cleared in another loses first: without the
        // mirror's `sawOutput` announcing, this list is all `.wentQuiet` and a run that talked
        // again keeps its mark until it exits.
        #expect(
            notices.contains(.startedTalkingAgain),
            Comment(rawValue: "a run that talked again announced only \(notices)")
        )
        // A silence is announced once and withdrawn once. Only the watchdog sets the latch, so a
        // recovery cannot come first; two of either in a row is a latch that stopped latching.
        #expect(notices.first == .wentQuiet, "a recovery cannot precede a silence")
        let alternates = zip(notices, notices.dropFirst()).allSatisfy { $0 != $1 }
        #expect(alternates, Comment(rawValue: "notices did not alternate: \(notices)"))

        killer.cancel()
        await killer.value
        #expect(!killerFired.value)
    }

    /// ⛔ **"The child must not exist afterwards" cannot be asserted by looking for the absence of
    /// a side effect, and the first version of this test proved it.** It armed `FAKE_ACP_READY`
    /// and asserted the file was absent after the throw. Break-tested by moving the guard to
    /// *after* `AgentSession` was constructed — i.e. with an agent genuinely spawned — and the
    /// test **passed anyway**: `#expect` runs microseconds after `start` returns, long before
    /// python has reached its first statement, so the evidence had not had time to arrive. An
    /// absent file is what a build that never spawned and a build that spawned a moment ago both
    /// look like. Waiting for it would trade the race for a wall-clock assertion, which this
    /// suite's rules forbid for the same reason.
    ///
    /// So the refusal is measured **synchronously, against the spawn's own first check**:
    /// `ChildProcess.init` refuses a non-existent executable with `ProcessError.notExecutable`
    /// before it constructs a `Process` at all. Point the agent at a path that does not exist and
    /// the two orderings give two different errors, deterministically and with nothing to wait
    /// for. The control below is what makes that discriminating rather than merely true.
    @Test("extra allowed tools are refused before the agent is spawned")
    func unmappableRunTermsRefuse() throws {
        let home = TestHome.scratch("acp-refusal")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var ghost = Self.agent()
        ghost.executable = "/usr/bin/definitely-not-here-9f3a"

        #expect(throws: AgentInvocationError.self) {
            _ = try AgentRun.start(
                invocation: Self.invocation(extraAllowedTools: ["Bash(git push:*)"]),
                agent: ghost,
                logURL: home.appendingPathComponent("never.jsonl")
            )
        }

        // ⚠️ The positive witness. Without it the assertion above would also pass for a `start`
        // that threw the refusal for some other reason, or that never reached the spawn at all
        // because the whole path was broken: this shows that the spawn IS reached and DOES refuse
        // that executable, so the only thing separating the two cases is which check ran first.
        #expect(throws: ProcessError.self) {
            _ = try AgentRun.start(
                invocation: Self.invocation(),
                agent: ghost,
                logURL: home.appendingPathComponent("spawned.jsonl")
            )
        }
    }
}
