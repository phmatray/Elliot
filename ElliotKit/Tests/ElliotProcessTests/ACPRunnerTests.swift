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

        killer.cancel()
        await killer.value
        #expect(!killerFired.value)
    }

    @Test("extra allowed tools are refused before the agent is spawned")
    func unmappableRunTermsRefuse() async throws {
        let refused = TestHome.scratch("acp-refusal")
        try FileManager.default.createDirectory(at: refused, withIntermediateDirectories: true)
        let refusedReady = refused.appendingPathComponent("ready").path

        #expect(throws: AgentInvocationError.self) {
            _ = try AgentRun.start(
                invocation: Self.invocation(extraAllowedTools: ["Bash(git push:*)"]),
                agent: Self.agent(environment: ["FAKE_ACP_READY": refusedReady]),
                logURL: refused.appendingPathComponent("never.jsonl")
            )
        }
        #expect(!FileManager.default.fileExists(atPath: refusedReady))

        // ⚠️ The positive witness for that negative. `FAKE_ACP_READY` proves nothing on its own —
        // an absent file is also what a broken harness produces — so the same mechanism is driven
        // once through a start that IS allowed, and the file must appear.
        let allowed = TestHome.scratch("acp-refusal-control")
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        let allowedReady = allowed.appendingPathComponent("ready").path
        let run = try AgentRun.start(
            invocation: Self.invocation(),
            agent: Self.agent(environment: ["FAKE_ACP_READY": allowedReady]),
            logURL: allowed.appendingPathComponent("run.jsonl")
        )
        let (killer, _) = armKiller { run.session.transport.terminate() }
        defer { killer.cancel() }
        _ = await Self.drain(run)
        #expect(FileManager.default.fileExists(atPath: allowedReady))
        killer.cancel()
    }
}
