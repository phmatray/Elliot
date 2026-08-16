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
        extraAllowedTools: [String] = [],
        maxBudgetUSD: Double? = nil,
        resumeFromAgentSession: String? = nil
    ) -> AgentInvocation {
        AgentInvocation(
            runID: UUID(),
            prompt: "go",
            cwd: cwd,
            permissionMode: permissionMode,
            extraAllowedTools: extraAllowedTools,
            extraDirectories: [],
            maxBudgetUSD: maxBudgetUSD,
            resumeFromAgentSession: resumeFromAgentSession
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
    /// (`collectSilences`) stated the same shape one runner over — the two were the same eight
    /// lines because they were one question asked of two enums — and it was deleted with
    /// `ClaudeRunner.swift` in Stage 1 of #379. This is now the only copy.
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

    /// Cancelling is two acts and the second is not optional: `session/cancel` asks the agent to
    /// stop, and the Node child must **still** be killed.
    ///
    /// ⛔ **`FAKE_ACP_MODE=hang` cannot exercise the second half, and using it here would make this
    /// test pass without the backstop existing.** `fake-acp.py`'s main loop is
    /// `while True: read_message(STDIN)` with a `break` on `None`, so under `hang` the stdin close
    /// `session.end()` performs is by itself enough to end the double — the kill is never needed
    /// and never observed. `MODE=deaf` was written for this task and for this reason: it answers
    /// the handshake, never answers `session/prompt`, and **ignores EOF on stdin**, so nothing but
    /// the escalation ends it. Verified by hand before this test was trusted — fed a handshake and
    /// a prompt down a fifo, still `ALIVE` two seconds after the fifo was closed, `GONE` with exit
    /// 143 a second after `kill -TERM`.
    ///
    /// ⚠️ The two halves fail for different reasons and both are needed. **Phase 1** is what failed
    /// on the unmodified tree, watched before a line of the fix was written: `cancel()` was
    /// `Task { await session.end() }`, so no `session/cancel` was ever sent and this went red as
    /// `(finished.stderr → "").contains("session/cancel")`. **Phase 2** could not fail that way —
    /// the old `cancel()` killed *immediately*, so the child assertion was green for the wrong
    /// reason — and is pinned by break-test instead: with `await session.end()` deleted from the
    /// deadline, the deaf child never dies, the turn never finishes, and this test went red at
    /// 20.5 s on `killerFired → true`. ⛔ **That is the shape of the red to expect**, and it is
    /// indirect on purpose: the run can only complete when the child does, so `armKiller` is what
    /// converts the regression from a hung `swift test` into a named failure. Phase 1's assertion
    /// stayed green throughout that break, which is what makes the two independent.
    ///
    /// The receipt is `outcome.stderr`, because the run log cannot carry it: the log mirrors the
    /// adapter's **stdout**, and `session/cancel` goes the other way, to its stdin.
    @Test("cancelling asks first and kills second")
    func cancelIsTwoPhase() async throws {
        let logURL = try Self.logURL("acp-cancel")
        let run = try AgentRun.start(
            invocation: Self.invocation(),
            agent: Self.agent(mode: "deaf"),
            logURL: logURL,
            // Short on purpose: the shipped ten seconds would be slept on every `swift test`, and
            // nothing here asserts how long anything took — only what happened and in what order.
            cancelGrace: .milliseconds(200)
        )
        let (killer, killerFired) = armKiller { run.session.transport.terminate() }
        defer { killer.cancel() }
        let pid = run.processIdentifier

        // Cancelled on the `.session` event rather than on `.started` or after a sleep: it is the
        // one moment that is both deterministic and late enough for there to be a session to
        // cancel — `session/new` has returned by the time this is yielded. One loop, so the stream
        // keeps exactly one consumer.
        var aliveAtCancel = false
        var outcome: AgentRunOutcome?
        for await update in run.updates {
            switch update {
            case .event(.session):
                aliveAtCancel = AgentSessionLifetimeTests.isAlive(pid)
                run.cancel()
            case .finished(let finished):
                outcome = finished
            case .started, .event, .stalled, .resumed:
                break
            }
        }

        // The positive witness. Without it "the child is gone" would also hold for a child that
        // never started — which is the shape `unmappableRunTermsRefuse` records getting wrong.
        #expect(aliveAtCancel)

        let finished = try #require(outcome)
        // Phase 1: the agent was **asked**. Red on an unmodified tree, where nothing ever writes a
        // `session/cancel` at all.
        #expect(
            finished.stderr.contains("session/cancel"),
            Comment(rawValue: "the agent was never asked to stop; stderr was \(finished.stderr)")
        )
        // Phase 2: and killed anyway. `AgentSessionLifetimeTests`' poll rather than a third copy of
        // it — killing is asynchronous, so a single read straight after would be its own race.
        #expect(await AgentSessionLifetimeTests.waitUntilGone(pid))
        // ⛔ And the outcome does not claim a stop reason the agent never sent. `deaf` never
        // answers the prompt, so the turn has no verdict — `RunState.cancelled` comes from
        // `RunScheduler`'s own knowledge here, not from anything in this value.
        #expect(finished.summary == nil)
        #expect(finished.summary?.stopReason == nil)

        killer.cancel()
        await killer.value
        #expect(!killerFired.value)
    }

    /// A cancel arriving before the handshake has opened a session goes straight to the backstop.
    ///
    /// ⛔ **Not an optimisation — the branch exists because the grace is meaningless without a
    /// session to name.** No `session/cancel` can be sent, so sleeping the window would be pure
    /// delay, and the commonest reason a run has no session id is a handshake that is itself
    /// wedged: an `npx` that cannot resolve the adapter, a Node that never answers `initialize`.
    /// That is exactly when somebody reaches for cancel, and making them wait ten seconds for
    /// nothing is the behaviour this pins against.
    ///
    /// `/bin/sleep 600` is the agent because it answers **nothing** — the same child
    /// `AgentSessionLifetimeTests.deafAgent()` uses, one rung further back: `initialize` never
    /// returns, so `cancelState.sessionId` stays nil for the whole life of the run. The grace is a
    /// deliberately absurd sixty seconds, so "gone within ten" can only be true if it was skipped.
    /// Nothing measures a duration; the claim is "gone by the deadline", as everywhere else here.
    ///
    /// Break-tested by moving the sleep out of the `if let sessionId` — the uniform shape, which is
    /// the tempting simplification: this test alone went red at 10.0 s on `waitUntilGone`, and the
    /// other eight stayed green.
    @Test("cancelling a run that never opened a session does not wait out the grace")
    func cancelWithoutASessionSkipsTheGrace() async throws {
        let logURL = try Self.logURL("acp-cancel-nosession")
        let mute = ACPAgentProcess(
            executable: "/bin/sleep", arguments: ["600"], cwd: "/tmp", environment: [:])
        let run = try AgentRun.start(
            invocation: Self.invocation(), agent: mute, logURL: logURL, cancelGrace: .seconds(60))
        let (killer, killerFired) = armKiller { run.session.transport.terminate() }
        // Belt and braces: with the branch deleted this test goes red while the child is still
        // alive, and the run's own teardown would not reach it for another minute.
        defer {
            killer.cancel()
            run.session.transport.terminate(hardKillAfter: .milliseconds(100))
        }
        let pid = run.processIdentifier

        #expect(AgentSessionLifetimeTests.isAlive(pid))
        run.cancel()
        // Ten seconds is comfortably above the healthy path — `Client.defaultFlushGrace` is two —
        // and comfortably below the grace this run was given.
        #expect(await AgentSessionLifetimeTests.waitUntilGone(pid, within: .seconds(10)))

        killer.cancel()
        await killer.value
        #expect(!killerFired.value)
    }

    /// A `cancelled` stop reason survives the trip from the wire to `TurnSummary` and to the log.
    ///
    /// ⚠️ **The plumbing, and deliberately not the agent.** `session/cancel` is on `fake-acp.py`'s
    /// cannot-express list — it is a no-op notification there, announced on stderr and changing
    /// nothing — so *"a `session/cancel` actually ending a turn"* is not covered by this suite and
    /// this test must not be read as covering it. What it pins is that when an agent does answer
    /// with `cancelled`, Elliot carries the word through rather than folding it into the failure
    /// path: `StopReason.cancelled` decodes, `isError` stays false (only `.refusal` sets it), and
    /// the archive can be read back for it.
    ///
    /// ⚠️ **It was green on an unmodified tree**, so it drove no code — it is a pin, and the only
    /// thing that makes a pin worth its line is knowing it can fail. Break-tested by replacing
    /// `stopReason: response.stopReason.rawValue` with the literal `"end_turn"`: red on both the
    /// outcome and the log, and on nothing else in the suite.
    @Test("an agent that answers a cancel reports it as the stop reason")
    func aCancelledTurnSaysSo() async throws {
        let logURL = try Self.logURL("acp-cancelled-stop")
        let run = try AgentRun.start(
            invocation: Self.invocation(),
            agent: Self.agent(environment: ["FAKE_ACP_STOP_REASON": "cancelled"]),
            logURL: logURL
        )
        let (killer, killerFired) = armKiller { run.session.transport.terminate() }
        defer { killer.cancel() }

        let (_, outcome) = await Self.drain(run)

        #expect(outcome?.summary?.stopReason == "cancelled")
        // Not an error: a turn that was asked to stop and stopped did what it was told.
        #expect(outcome?.summary?.isError == false)
        // And the file says the same, since that is the only copy a later reader has.
        let terminal = try #require(try Self.objects(inLogAt: logURL).last)
        let params = try #require(terminal["params"] as? [String: Any])
        #expect(params["stopReason"] as? String == "cancelled")

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

    /// Task 11: `--max-budget-usd` went with the CLI, and the per-run spend ceiling is rebuilt on
    /// live `usage_update` + `session/cancel`. `Fixtures/acp/usage-over-budget.json` carries one
    /// `usage_update` frame reporting `cost: 0.2855775` — the same recorded figure
    /// `aTurnStreamsAndLogs` pins on `fake-simple-turn.json` — against a ceiling of `0.10`.
    ///
    /// ⚠️ **Sampled five times, not once.** `fake-acp.py` writes every fixture frame and then
    /// immediately replies to `session/prompt` in the same breath (`Scripts/fake-acp.py:283-284`),
    /// so the brake's decision (made asynchronously, off the notification consumer) and the
    /// response already in flight race by construction — a single green run would prove nothing
    /// about which one the summary reflected. It is the `braked` override in `AgentRun.summary`
    /// that makes the answer stable regardless of who wins that race; this is the test that would
    /// otherwise be intermittent rather than wrong-answered.
    ///
    /// ⛔ **This test must not be read as covering the cancellation itself.** It was named *"a run
    /// that crosses its ceiling is cancelled, and says which ceiling"* until code review, and the
    /// first half of that was a claim no assertion here could see: deleting `Self.requestCancel(…)`
    /// from `brake()` left the whole suite green — 2865 tests, measured — which is the ceiling
    /// ceasing to stop anything while these two assertions still pass. What is asserted below is
    /// what the summary *says*; that Elliot actually asked the agent to stop is
    /// `theBrakeAsksTheAgentToStop`'s claim, and it needs a different agent mode to make it.
    ///
    /// ⚠️ **And do not close that gap by adding `#expect(stderr.contains("session/cancel"))` here.**
    /// Measured twice, exactly that assertion in exactly this scenario: **13 of 15** samples came
    /// back with empty stderr when it was first recorded, and **14 of 15** on an independent
    /// re-measurement. (Re-measured rather than quoted, and the two figures are the same finding:
    /// the receipt is the exception, not the rule. Neither is a constant — it is a race, and the
    /// count is whatever the machine did that afternoon, which is the reason this must not become
    /// an assertion.) The reason is that under `MODE=ok` the double replies to `session/prompt`
    /// in the same breath as the frame that fired the brake, so the turn task tears the session
    /// down — `session.end()` → `Client.terminate()` → `ACPTransport.close()` → `closeStdin()` —
    /// before the brake's `sendCancelNotification` has written its line, and the write throws
    /// `ProcessError.stdinClosed` into phase 1's `try?`. The failure is in the scenario, not in
    /// the brake. (This said "the turn task cancels that task" and blamed a swallowed
    /// `CancellationError`; instrumented at the send site, 19 of 20 `MODE=ok` samples threw
    /// `stdinClosed` and `Task.isCancelled` was false in 19 of 20. `brake()`'s ⚠️ carries it.)
    @Test("a run that crosses its ceiling says which ceiling stopped it")
    func theBudgetBrakeFires() async throws {
        for _ in 0..<5 {
            let logURL = try Self.logURL("acp-brake-fires")
            let run = try AgentRun.start(
                invocation: Self.invocation(maxBudgetUSD: 0.10),
                agent: Self.agent(fixture: "usage-over-budget.json"),
                logURL: logURL
            )
            let (killer, killerFired) = armKiller { run.session.transport.terminate() }
            defer { killer.cancel() }

            let (_, outcome) = await Self.drain(run)

            #expect(outcome?.summary?.stopReason == AgentRun.maxBudgetStopReason)
            #expect(outcome?.summary?.isError == true)

            killer.cancel()
            await killer.value
            #expect(!killerFired.value)
        }
    }

    /// ⛔ **The half of the brake that actually stops a run, pinned where it can be seen.** The
    /// test above pins what the summary *says*; nothing pinned the `session/cancel` the brake
    /// sends, and the difference is not academic — with `Self.requestCancel(…)` deleted from
    /// `brake()` the suite stayed green at 2865 tests while `stopReason` still read
    /// `elliot/max_budget` and `isError` still read `true`. That summary tells a human Elliot
    /// stopped a run for spending too much, about a run Elliot did not stop.
    ///
    /// ⚠️ **It needs `MODE=deaf-after-fixture`, and the reason is measured rather than stylistic.**
    /// Under `MODE=ok` the double replies to `session/prompt` in the same breath as the fixture's
    /// last frame, so the turn task resumes and tears the session down — `await session.end()` →
    /// `Client.terminate()` → `ACPTransport.close()` → `closeStdin()` — while phase 1, the
    /// `try? await client.sendCancelNotification` inside the deadline task, is still on its way to
    /// the wire. The write then meets a closed stdin and throws `ProcessError.stdinClosed`, which
    /// that `try?` swallows, so the ask is never written: asserting the receipt in
    /// `theBudgetBrakeFires` gave **13 empty-stderr failures in 15 samples** when first recorded,
    /// and **14 of 15** on an independent re-measurement.
    ///
    /// ⛔ **What is swallowed is `stdinClosed`, not a `CancellationError` — this comment claimed
    /// the latter and it does not happen.** Instrumented with a `do`/`catch` at the send site:
    /// under `MODE=ok`, 19 of 20 samples threw `ProcessError.stdinClosed` and `Task.isCancelled`
    /// read **false in 19 of 20** immediately before the send, the one cancelled sample throwing
    /// `stdinClosed` too. Under this mode, 5 of 5 sent successfully. Nothing between the deadline
    /// task and the write observes cancellation, so the deadline being cancelled cannot be what
    /// loses the ask.
    ///
    /// `MODE=deaf` cannot serve either, one rung the other way — it returns before
    /// `for update in fixture()`, so no `usage_update` is ever emitted and the brake has nothing to
    /// fire on. The new mode emits the frame and then leaves the turn open, so nothing tears the
    /// transport down and the brake's ask is the only thing that can end the run.
    ///
    /// ⛔ **The red to expect from a regression is indirect**, exactly as `cancelIsTwoPhase`
    /// records: with the ask gone, nothing ever ends this turn, so `armKiller` is what turns a hung
    /// `swift test` into a named failure on `killerFired`.
    ///
    /// The receipt is `outcome.stderr` for that test's reason too — the log mirrors the adapter's
    /// **stdout**, and `session/cancel` goes the other way, to its stdin.
    ///
    /// ⚠️ **What is still not covered is an agent honouring it.** `session/cancel` is on
    /// `fake-acp.py`'s cannot-express list — a deliberate no-op announced on stderr — so what ends
    /// this child is phase 2, the backstop kill. This pins that Elliot **asked**, never that an
    /// adapter obeyed, and no test in this suite covers the latter.
    @Test("crossing the ceiling asks the agent to stop")
    func theBrakeAsksTheAgentToStop() async throws {
        let logURL = try Self.logURL("acp-brake-asks")
        let run = try AgentRun.start(
            invocation: Self.invocation(maxBudgetUSD: 0.10),
            agent: Self.agent(mode: "deaf-after-fixture", fixture: "usage-over-budget.json"),
            logURL: logURL,
            // Short on purpose, as in `cancelIsTwoPhase`: the shipped ten seconds would be slept on
            // every `swift test`, and nothing here asserts how long anything took — only what
            // happened.
            cancelGrace: .milliseconds(200)
        )
        let (killer, killerFired) = armKiller { run.session.transport.terminate() }
        defer { killer.cancel() }

        let (events, outcome) = await Self.drain(run)

        // The positive witness. Without it an empty fixture, or one whose frame carried no cost,
        // would look exactly like a brake that fired and asked — the shape
        // `unmappableRunTermsRefuse` records getting wrong.
        #expect(events.contains { if case .usage = $0 { true } else { false } })

        let finished = try #require(outcome)
        #expect(
            finished.stderr.contains("session/cancel"),
            Comment(rawValue: "the agent was never asked to stop; stderr was \(finished.stderr)")
        )
        // ⛔ And no summary, which is the honest consequence of the mode rather than an omission:
        // the prompt was never answered, so there is no response for `braked` to override. The
        // stop reason is the test above's claim; this one's is the ask.
        #expect(finished.summary == nil)

        killer.cancel()
        await killer.value
        #expect(!killerFired.value)
    }

    /// The other collision Task 11 has to win, and it is not hypothetical either: `brake()` calls
    /// the Task 10 cancel path, which sends `session/cancel`, which a real agent answers with
    /// `stopReason: "cancelled"` — Elliot's own spend ceiling reported as a user cancellation, on
    /// a card whose run cost more than it was allowed to. `FAKE_ACP_STOP_REASON=cancelled` makes
    /// `fake-acp.py` answer that way regardless, so both answers are genuinely available and the
    /// brake's must win.
    @Test("a braked run does not report the cancellation it used to stop itself")
    func theBrakeOutranksTheCancel() async throws {
        let logURL = try Self.logURL("acp-brake-outranks-cancel")
        let run = try AgentRun.start(
            invocation: Self.invocation(maxBudgetUSD: 0.10),
            agent: Self.agent(
                fixture: "usage-over-budget.json",
                environment: ["FAKE_ACP_STOP_REASON": "cancelled"]
            ),
            logURL: logURL
        )
        let (killer, killerFired) = armKiller { run.session.transport.terminate() }
        defer { killer.cancel() }

        let (_, outcome) = await Self.drain(run)

        #expect(outcome?.summary?.stopReason == AgentRun.maxBudgetStopReason)

        killer.cancel()
        await killer.value
        #expect(!killerFired.value)
    }

    /// `maxBudgetUSD: nil` is "no ceiling — the default"
    /// (`AgentInvocation.maxBudgetUSD`'s doc comment), so the same over-ceiling fixture must run
    /// to its ordinary end.
    // MARK: - Resuming

    /// ⛔ **The narrowing this task calls "the whole point", pinned — because for one commit it
    /// was pinned by nothing.** The decision used to be spelled as two constructs at the catch
    /// site, `catch let error as ClientError` plus an inner `guard case .agentError`, and only the
    /// outer one was reachable: `FAKE_ACP_FORK_UNREADABLE` makes `Client.forkSession` throw a bare
    /// `DecodingError` (it calls `decoder.decode` directly rather than wrapping), which the type
    /// filter already rejects. Measured: deleting the inner guard left the **entire suite green**,
    /// 2874 tests in 337 suites. So `.requestTimeout`, `.connectionClosed`, `.invalidResponse` and
    /// `.decodingError` were routed to "the agent refused" by a line no test could fail on.
    ///
    /// `isForkRefusal` exists so the decision has a name a test can call, and this is that test:
    /// every case the vendored `ClientError` declares, plus the two non-`ClientError` throws this
    /// call site can actually meet.
    ///
    /// ⚠️ **Listed by hand, because it cannot be enumerated.** `ClientError`'s associated values
    /// bar `CaseIterable`, so a thirteenth case added to the vendored enum would not fail here —
    /// it would simply go unmeasured, and the default answer for anything unlisted is `false`, the
    /// safe one. The count assertion below is the tripwire for that: it fails if this list stops
    /// matching the enum's arity.
    @Test("only an answer from the agent counts as a refused fork")
    func onlyAnAgentAnswerIsARefusal() {
        let refused = JSONRPCError(
            code: -32002, message: "Resource not found: sess-that-never-was", data: nil)
        // Every case `ACPModel/Errors.swift` declares, in declaration order.
        let clientErrors: [(ClientError, Bool)] = [
            (.processNotRunning, false),
            (.processFailed(1), false),
            (.invalidResponse, false),
            (.requestTimeout, false),
            (.encodingError, false),
            (.decodingError(DecodingError.valueNotFound(String.self, .init(
                codingPath: [], debugDescription: "no sessionId"))), false),
            (.agentError(refused), true),
            (.delegateNotSet, false),
            (.fileNotFound("/tmp/nope"), false),
            (.fileOperationFailed("/tmp/nope"), false),
            (.transportError("pipe closed"), false),
            (.connectionClosed, false),
        ]
        #expect(clientErrors.count == 12, "ClientError gained or lost a case; extend this list")
        for (error, expected) in clientErrors {
            #expect(
                AgentRun.isForkRefusal(error) == expected,
                Comment(rawValue: "\(error) should \(expected ? "" : "not ")be a refusal")
            )
        }

        // ⛔ The one that is reachable today, and the reason the parameter is `Error` and not
        // `ClientError`: `Client.forkSession` lets a decode failure escape unwrapped.
        #expect(!AgentRun.isForkRefusal(DecodingError.keyNotFound(
            ForkKey.sessionId,
            .init(codingPath: [], debugDescription: "no sessionId"))))
        // A turn cancelled out from under the handshake establishes nothing about the transcript
        // either — and unlike the rest, this one arrives without any agent involvement at all.
        #expect(!AgentRun.isForkRefusal(CancellationError()))
    }

    /// Only so the `DecodingError.keyNotFound` above has a `CodingKey` to name; the real one is
    /// `ForkSessionResponse`'s, which is synthesised and private.
    private enum ForkKey: String, CodingKey { case sessionId }

    /// Task 13: a resumed run asks for `session/fork`, and adopts **the id the agent answered
    /// with** rather than the one it asked about.
    ///
    /// ⛔ **The two ids differ on purpose, and that is what makes this discriminating.**
    /// `fake-acp.py` answers a fork with `sess-fake-fork-0002` where `session/new` answers
    /// `sess-fake-0001`, so a runner that quietly opened a new session instead of forking — the
    /// tempting shape, since it always produces a working turn — comes back with the wrong string
    /// here rather than with a green test. Break-tested by replacing the fork call with
    /// `newSession`: red on `agentSessionID`, on the log's session line, and on the stderr receipt.
    ///
    /// ⚠️ **What the double does on `session/fork` is its own invention, not a recording** — the
    /// real adapter advertises the capability and, at the time this was written, nothing had ever
    /// called it. So this pins Elliot's half: that a fork is what a resumed run asks for, and that
    /// its answer is what the run adopts. Step 4 of the brief measures the adapter's half by hand.
    @Test("a resumed run forks, and takes the session the agent handed back")
    func aResumedRunForksTheSession() async throws {
        let logURL = try Self.logURL("acp-fork-ok")
        let run = try AgentRun.start(
            invocation: Self.invocation(resumeFromAgentSession: "sess-parent-0001"),
            agent: Self.agent(environment: ["FAKE_ACP_FORKABLE": "sess-parent-0001"]),
            logURL: logURL
        )
        let (killer, killerFired) = armKiller { run.session.transport.terminate() }
        defer { killer.cancel() }

        let (events, outcome) = await Self.drain(run)

        let finished = try #require(outcome)
        // The receipt, for the reason `cancelIsTwoPhase` gives: the log mirrors the adapter's
        // stdout, and a request Elliot sent went the other way, to its stdin.
        #expect(
            finished.stderr.contains("session/fork for 'sess-parent-0001'"),
            Comment(rawValue: "the agent was never asked to fork; stderr was \(finished.stderr)")
        )
        #expect(finished.agentSessionID == "sess-fake-fork-0002")
        #expect(finished.sessionResumeFailed == false)
        // And the turn really ran on it — a fork whose session nothing can prompt is not a resume.
        #expect(finished.summary?.stopReason == "end_turn")
        #expect(events.contains { if case .agentText = $0 { true } else { false } })

        // The log's first record names the forked session, not the parent: `elliot/session` is
        // what a later reader has instead of this outcome.
        let objects = try Self.objects(inLogAt: logURL)
        let line = try #require(objects.first { $0["method"] as? String == AgentLog.sessionMethod })
        let params = try #require(line["params"] as? [String: Any])
        #expect(params["agentSessionID"] as? String == "sess-fake-fork-0002")
        // ⛔ `ForkSessionResponse` declares no `models` field at all, so on this path
        // `AgentRun.model(in:)`'s `configOptions` fallback is the ONLY route to a model name.
        // `theLogIsSelfDescribing` pins that fallback for `session/new`; this pins that folding the
        // two responses together did not lose it.
        #expect(params["model"] as? String == "opus[1m]")

        killer.cancel()
        await killer.value
        #expect(!killerFired.value)
    }

    /// A fork the agent **refused** ends the run, says so, and does not quietly start a fresh
    /// session — which would run the work a second time against a transcript nobody asked for.
    ///
    /// `FAKE_ACP_FORKABLE` is unset, so the double refuses every fork, exactly as it refuses a
    /// `session/prompt` for a session it never issued.
    ///
    /// ⛔ **`agentSessionID == nil` is the assertion that catches the silent fall-back**, and it is
    /// the one worth reading twice: a runner that caught the refusal and called `newSession`
    /// anyway would come back with `sess-fake-0001` and a perfectly ordinary `end_turn` — a green
    /// run, having done the work, on a card whose whole point was to continue an earlier one.
    /// Break-tested exactly that way: red here, on `sessionResumeFailed`, on `summary`, and on the
    /// terminal line's `isError`.
    @Test("a fork the agent refused ends the run instead of starting a fresh session")
    func aRefusedForkEndsTheRun() async throws {
        let logURL = try Self.logURL("acp-fork-refused")
        let run = try AgentRun.start(
            invocation: Self.invocation(resumeFromAgentSession: "sess-that-never-was"),
            agent: Self.agent(),
            logURL: logURL
        )
        let (killer, killerFired) = armKiller { run.session.transport.terminate() }
        defer { killer.cancel() }

        let (events, outcome) = await Self.drain(run)

        let finished = try #require(outcome)
        // The positive witness: the agent WAS asked. Without it every assertion below would also
        // hold for a run that fell over before it got as far as forking — the shape
        // `unmappableRunTermsRefuse` records getting wrong.
        #expect(
            finished.stderr.contains("session/fork for 'sess-that-never-was'"),
            Comment(rawValue: "the agent was never asked to fork; stderr was \(finished.stderr)")
        )
        #expect(finished.sessionResumeFailed)
        #expect(finished.agentSessionID == nil)
        #expect(!events.contains { if case .agentText = $0 { true } else { false } })

        // ⛔ A terminal line IS written here, and the ordinary died-mid-turn path writes none. That
        // is the difference between "this run ended, having done nothing" and "we do not know what
        // happened to this run", and the archive has only the file to read it off.
        let summary = try #require(finished.summary)
        #expect(summary.isError)
        // ⛔ Named, not nil. With `stopReason: nil` — the brief's literal value, and what this
        // shipped as for one commit — `LogRows.summary` draws this run as a bare "Finished with
        // issues", because it appends a reason only when there is one. That is the single failure
        // a relaunch can fix, rendered as an unexplained one, with `SkillRun.stopReason` storing
        // nothing. Same namespace and same precedent as `maxBudgetStopReason`.
        #expect(summary.stopReason == AgentRun.sessionForkRefusedStopReason)
        let objects = try Self.objects(inLogAt: logURL)
        #expect(objects.last?["method"] as? String == AgentLog.terminalMethod)
        // The file and the value handed to the caller are the same value, which is the invariant
        // `AgentLogTests.theTerminalLineIsNotLostToTheExit` states for the ordinary path.
        #expect(AgentLog.lastSummary(inLogAt: logURL) == summary)

        killer.cancel()
        await killer.value
        #expect(!killerFired.value)
    }

    /// ⛔ **Refused and unreadable are not the same answer, and this is the test that keeps them
    /// apart.** An agent that answers *"no such session"* has established that the transcript is
    /// gone; a reply nobody can decode establishes only that nobody could ask. `ResumeVerdict` has
    /// a name for the second — `.ran`, "everything else, including we do not know" — and reporting
    /// `.sessionGone` for it would assert a missing transcript on evidence that does not say so,
    /// and in Task 15's relaunch policy spend an attempt on that assertion.
    ///
    /// So `AgentRun.start` narrows to `ClientError.agentError` — the agent *answering* a refusal —
    /// and lets everything else fall through to the ordinary died-mid-turn path: no terminal line,
    /// no summary, `sessionResumeFailed` false. `FAKE_ACP_FORK_UNREADABLE` answers the fork with
    /// `result: {}`, which `ForkSessionResponse` cannot decode (it requires `sessionId`), so the
    /// throw is a `DecodingError` and not a `ClientError` at all.
    ///
    /// Break-tested by widening the catch to a bare `catch { sessionResumeFailed = true }`: red on
    /// `sessionResumeFailed` and on `summary`, with `aRefusedForkEndsTheRun` staying green — which
    /// is the point, since the wide catch is the version that looks right in one test and reports
    /// a lost transcript in the other.
    @Test("a fork answered with something unreadable is not a refusal")
    func anUnreadableForkAnswerIsNotARefusal() async throws {
        let logURL = try Self.logURL("acp-fork-unreadable")
        let run = try AgentRun.start(
            invocation: Self.invocation(resumeFromAgentSession: "sess-parent-0001"),
            agent: Self.agent(environment: [
                "FAKE_ACP_FORKABLE": "sess-parent-0001",
                "FAKE_ACP_FORK_UNREADABLE": "1",
            ]),
            logURL: logURL
        )
        let (killer, killerFired) = armKiller { run.session.transport.terminate() }
        defer { killer.cancel() }

        let (_, outcome) = await Self.drain(run)

        let finished = try #require(outcome)
        #expect(finished.stderr.contains("session/fork for 'sess-parent-0001'"))
        // Nothing was established, so nothing is claimed: `ResumeVerdict.of` reads this as `.ran`,
        // the safe answer that costs a verification which would have happened anyway.
        #expect(finished.sessionResumeFailed == false)
        #expect(ResumeVerdict.of(
            resumedFrom: UUID(), sessionResumeFailed: finished.sessionResumeFailed) == .ran)
        // The died-mid-turn shape, whose whole meaning is the ABSENCE of a terminal line.
        #expect(finished.summary == nil)
        #expect(finished.agentSessionID == nil)
        #expect(AgentLog.lastSummary(inLogAt: logURL) == nil)

        killer.cancel()
        await killer.value
        #expect(!killerFired.value)
    }

    /// The other half of the narrowing, end to end: a `ClientError` that is **not**
    /// `.agentError`. `anUnreadableForkAnswerIsNotARefusal` above drives an error that is not a
    /// `ClientError` at all, so between them they cover both of `isForkRefusal`'s tests — and
    /// until this test existed, the inner one was reachable from no test in the suite.
    ///
    /// `FAKE_ACP_FORK_DIES` exits the double at `session/fork` without answering, so the client's
    /// read loop finishes and `handleTermination` fails the pending request with
    /// `ClientError.connectionClosed`. The agent went away mid-question; nobody established
    /// anything about the transcript, so `sessionResumeFailed` stays false and the run takes the
    /// ordinary died-mid-turn shape — **no terminal line at all**, which is the fact.
    @Test("a fork the agent died during is not a refusal")
    func aForkTheAgentDiedDuringIsNotARefusal() async throws {
        let logURL = try Self.logURL("acp-fork-died")
        let run = try AgentRun.start(
            invocation: Self.invocation(resumeFromAgentSession: "sess-parent-0001"),
            agent: Self.agent(environment: [
                "FAKE_ACP_FORKABLE": "sess-parent-0001",
                "FAKE_ACP_FORK_DIES": "1",
            ]),
            logURL: logURL
        )
        let (killer, killerFired) = armKiller { run.session.transport.terminate() }
        defer { killer.cancel() }

        let (_, outcome) = await Self.drain(run)

        let finished = try #require(outcome)
        // The positive witness: the agent really was asked, and died holding the question.
        #expect(
            finished.stderr.contains("session/fork for 'sess-parent-0001'"),
            Comment(rawValue: "the agent was never asked to fork; stderr was \(finished.stderr)")
        )
        #expect(finished.sessionResumeFailed == false)
        #expect(ResumeVerdict.of(
            resumedFrom: UUID(), sessionResumeFailed: finished.sessionResumeFailed) == .ran)
        #expect(finished.summary == nil)
        #expect(finished.agentSessionID == nil)
        #expect(AgentLog.lastSummary(inLogAt: logURL) == nil)

        killer.cancel()
        await killer.value
        #expect(!killerFired.value)
    }

    @Test("a run with no ceiling is never braked")
    func noCeilingNeverBrakes() async throws {
        let logURL = try Self.logURL("acp-brake-no-ceiling")
        let run = try AgentRun.start(
            invocation: Self.invocation(maxBudgetUSD: nil),
            agent: Self.agent(fixture: "usage-over-budget.json"),
            logURL: logURL
        )
        let (killer, killerFired) = armKiller { run.session.transport.terminate() }
        defer { killer.cancel() }

        let (_, outcome) = await Self.drain(run)

        #expect(outcome?.summary?.stopReason == "end_turn")
        #expect(outcome?.summary?.isError == false)

        killer.cancel()
        await killer.value
        #expect(!killerFired.value)
    }

    /// Measured (`AgentInvocation.maxBudgetUSD`'s doc comment, where the per-transcript indices
    /// are): **38 of the 42 recorded `usage_update` frames carry no `cost` at all**, so a costless
    /// frame is the ordinary case and not the corner. A brake reading that absence as `0.0` would
    /// be correct by accident against a ceiling like `0.10` and wrong the moment a ceiling is
    /// compared the other way — so this drives a ceiling of exactly `0.0` against
    /// `Fixtures/acp/usage-no-cost.json`, whose one `usage_update` frame reports `used`/`size` and
    /// no `cost` at all: `0.0 >= 0.0` would fire the brake on the very first frame if absence read
    /// as zero spend.
    @Test("a usage frame with no cost does not read as zero spend")
    func absentCostIsNotZero() async throws {
        let logURL = try Self.logURL("acp-brake-absent-cost")
        let run = try AgentRun.start(
            invocation: Self.invocation(maxBudgetUSD: 0.0),
            agent: Self.agent(fixture: "usage-no-cost.json"),
            logURL: logURL
        )
        let (killer, killerFired) = armKiller { run.session.transport.terminate() }
        defer { killer.cancel() }

        let (_, outcome) = await Self.drain(run)

        #expect(outcome?.summary?.stopReason == "end_turn")
        #expect(outcome?.summary?.isError == false)

        killer.cancel()
        await killer.value
        #expect(!killerFired.value)
    }

    /// ⛔ The by-value denial fold, pinned at the site that actually applies it.
    ///
    /// `NonExecutionKind.isDenial` was pinned, and so was the live pane — but the assembly site in
    /// `AgentRun.summary` that produces `TurnSummary.denials` → `SkillRun.permissionDenials` →
    /// `RunState` was **not**. The final whole-branch review switched that fold from by-value to
    /// by-presence (`call.nonExecutionKind != nil`) and measured the whole suite still green:
    /// 2886 tests, 0 failures. The rule this design argues for at greatest length was unpinned at
    /// its only production site.
    ///
    /// It survived because every fixture carrying a `nonExecutionKind` carried `permission-rule`,
    /// which is a denial under *both* folds — so the two rules could not disagree anywhere in the
    /// suite. `Fixtures/acp/fake-nonexecution-kinds.json` carries all four values the adapter's own
    /// source enumerates, and the two folds now disagree by three.
    ///
    /// The regression this prevents is not cosmetic. Elliot **cancels runs by design**, and a
    /// cancelled run's in-flight tool calls carry `interrupted`/`cancelled` — so under a by-presence
    /// fold every cancelled run would flip `.succeeded` → `.completedWithDenials`, telling the
    /// reader it *"was refused a tool and quietly worked around the gap"* about a run nothing
    /// refused, on the board's most common deliberate action.
    @Test("only permission-rule is a denial, and the other three are still recorded")
    func theDenialFoldIsByValueNotByPresence() async throws {
        let logURL = try Self.logURL("acp-nonexecution-kinds")
        let run = try AgentRun.start(
            invocation: Self.invocation(),
            agent: Self.agent(fixture: "fake-nonexecution-kinds.json"),
            logURL: logURL
        )
        let (killer, killerFired) = armKiller { run.session.transport.terminate() }
        defer { killer.cancel() }

        let (_, outcome) = await Self.drain(run)
        let summary = try #require(outcome?.summary)

        // ⛔ Exactly one — the only value measured against the mechanism Elliot ships (a `PreToolUse`
        // hook block, recorded at `Fixtures/acp/turn-refusal.json`). A by-presence fold returns all
        // four here, which is what makes this line the pin.
        #expect(summary.denials == ["Bash"])

        // ...and the other three are RECORDED rather than discarded. §5.4 keeps every value "for the
        // log and the card": a kind that is not folded is still a fact someone may need, and an
        // unrecognised fifth value must never be defaulted into a denial.
        #expect(summary.nonExecutionKinds.count == 4)
        #expect(summary.nonExecutionKinds.contains(.permissionRule))
        #expect(summary.nonExecutionKinds.contains(.interrupted))
        #expect(summary.nonExecutionKinds.contains(.cancelled))
        #expect(summary.nonExecutionKinds.contains(.userRejected))

        killer.cancel()
        await killer.value
        #expect(!killerFired.value)
    }
}
