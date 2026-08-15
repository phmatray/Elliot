import ElliotModel
import Foundation
import Testing
import TestSupport

@testable import ElliotProcess

/// What a finished run can still be asked, once nothing of it is running any more.
///
/// ⛔ **This is the half of crash recovery ACP takes away and Elliot has to put back.** Under
/// `claude -p` the terminal `result` was a stream-json line like any other, so the log was
/// self-sufficient for free and `ClaudeRun.lastResult(inLogAt:)` could recover the verdict of a run
/// whose decoder had crashed. Under ACP the `stopReason` comes back as the **response** to
/// `session/prompt`: it is never a notification, so it never enters the notification stream and
/// never reaches the log unless Elliot writes it there. Two tests below are about the scan and
/// three are about the writing, because a scan with nothing to find is the same defect wearing a
/// different face.
@Suite("Agent log")
struct AgentLogTests {
    /// A scratch `.jsonl` holding exactly these lines.
    static func log(_ lines: [String], label: String) throws -> URL {
        let home = TestHome.scratch(label)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appendingPathComponent("\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// One adapter `session/update` frame, as the mirror would have written it.
    static func notification(_ update: String) -> String {
        #"{"jsonrpc":"2.0","method":"session/update","params":"#
            + #"{"sessionId":"sess-fake-0001","update":"# + update + "}}"
    }

    static func text(_ line: Data) -> String {
        String(decoding: line, as: UTF8.self)
    }

    static let summary = TurnSummary(
        stopReason: "end_turn",
        text: "done",
        denials: ["Bash"],
        nonExecutionKinds: [.permissionRule],
        isError: false
    )

    /// ⚠️ The trailing notification is the whole point of the first assertion. A real log can
    /// carry a frame written **after** the terminal line — `AgentRun` mirrors under the drain lock
    /// and holds a partial frame back until its own newline arrives, so the last line of a log is
    /// not reliably the last thing that mattered. A scan that read the last line rather than the
    /// last *matching* one would miss the summary entirely and answer `nil`, which is
    /// indistinguishable from a run that died mid-turn.
    ///
    /// Break-tested by scanning `.reversed().prefix(1)` — the last line rather than the last
    /// matching one: red here on the `#require`, and red one test down on `sessionInfo`, which is
    /// the same defect seen from the other end of the file.
    @Test("the terminal summary is recovered from the log, not from memory")
    func summaryComesBackOffDisk() throws {
        let url = try Self.log(
            [
                Self.notification(#"{"sessionUpdate":"agent_message_chunk"}"#),
                Self.text(AgentLog.terminalLine(Self.summary)),
                Self.notification(#"{"sessionUpdate":"tool_call_update"}"#),
            ],
            label: "agentlog-summary"
        )

        let found = try #require(AgentLog.lastSummary(inLogAt: url))
        #expect(found.stopReason == "end_turn")
        #expect(found.denials == ["Bash"])
        #expect(found.text == "done")
        #expect(found.nonExecutionKinds == [.permissionRule])
    }

    @Test("the handshake is recovered from the log the same way")
    func sessionComesBackOffDisk() throws {
        let info = RunSessionInfo(
            agentSessionID: "sess-fake-0001",
            agentName: "fake-acp",
            agentVersion: "0.0.1",
            cwd: "/tmp",
            model: "opus[1m]",
            mode: "bypassPermissions"
        )
        let url = try Self.log(
            [
                Self.text(AgentLog.sessionLine(info)),
                Self.notification(#"{"sessionUpdate":"agent_message_chunk"}"#),
                Self.text(AgentLog.terminalLine(Self.summary)),
            ],
            label: "agentlog-session"
        )

        #expect(AgentLog.sessionInfo(inLogAt: url) == info)
        // The two scans ask different questions of the same file: a log carrying both must not
        // answer either one with the other's line.
        #expect(AgentLog.lastSummary(inLogAt: url)?.stopReason == "end_turn")
    }

    @Test("a log with no terminal line reports nothing rather than guessing")
    func noTerminalLineIsNil() throws {
        let url = try Self.log(
            [
                Self.text(AgentLog.sessionLine(RunSessionInfo(agentSessionID: "s", cwd: "/tmp"))),
                Self.notification(#"{"sessionUpdate":"agent_message_chunk"}"#),
                Self.notification(#"{"sessionUpdate":"tool_call"}"#),
            ],
            label: "agentlog-no-terminal"
        )

        #expect(AgentLog.lastSummary(inLogAt: url) == nil)
        // A missing file is the same answer as a file that never said, and for the same reason:
        // there is nothing to report, so nothing is reported.
        #expect(AgentLog.lastSummary(inLogAt: url.appendingPathExtension("gone")) == nil)
    }

    /// ⛔ **The namespace is the guarantee, and this test is built so that nothing else can be.**
    /// The spoofing line is a real `elliot/terminal` line with its method string swapped for
    /// `session/update` — so its `params` are byte-identical to a genuine summary and decode
    /// perfectly. A scan that decoded first and asked about the method afterwards, or never asked,
    /// would return it. Only the method check can tell these two lines apart.
    ///
    /// Break-tested by relaxing the scan's `envelope.method == method` to `envelope.method != nil`
    /// — i.e. "any line of ours" rather than "this record of ours": red here, and **nowhere else in
    /// 2 857 tests**, which is the measurement that says this assertion is the only thing holding
    /// the namespace guarantee up.
    @Test("an adapter frame can never be mistaken for Elliot's own record")
    func theNamespaceIsTheGuarantee() throws {
        let real = Self.text(AgentLog.terminalLine(Self.summary))
        // ⚠️ `JSONEncoder` escapes the forward slash, so on disk the method reads
        // `elliot\/terminal` and a swap written against the constant's own spelling matches
        // nothing. Measured — the first version of this test replaced `"elliot/terminal"`, changed
        // not one byte, and reported the untouched line as a spoof that got through. Both spellings
        // are swapped so the test survives Foundation changing its mind either way, and the two
        // guards below are what would say so if neither matched.
        let escaped = AgentLog.terminalMethod.replacingOccurrences(of: "/", with: #"\/"#)
        let spoof = real
            .replacingOccurrences(of: #""\#(escaped)""#, with: #""session\/update""#)
            .replacingOccurrences(of: #""\#(AgentLog.terminalMethod)""#, with: #""session/update""#)
        #expect(spoof != real, "the method swap found nothing to replace")
        #expect(!spoof.contains("elliot"), "the spoof still names Elliot's own namespace")
        #expect(spoof.contains(#""stopReason":"end_turn""#))

        let url = try Self.log([spoof], label: "agentlog-spoof")
        #expect(AgentLog.lastSummary(inLogAt: url) == nil)

        // The positive witness: the identical params under Elliot's own method **are** read. Without
        // it, a scan that always answered nil would pass the assertion above.
        let honest = try Self.log([real], label: "agentlog-honest")
        #expect(AgentLog.lastSummary(inLogAt: honest)?.stopReason == "end_turn")
    }

    /// The fact the whole design rests on: a run that died mid-turn is **distinguishable** from one
    /// that ended. `FAKE_ACP_MODE=crash` exits 9 inside `session/prompt`, so no response ever comes
    /// back, no terminal line is written, and the absence is the record.
    ///
    /// ⛔ Break-tested by giving the `if let response` an `else` that writes
    /// `TurnSummary(stopReason: "end_turn", isError: false)` — a guess, which is precisely what
    /// this design refuses. Red on both assertions here, in memory **and** on disk, and green
    /// everywhere else: a run that crashed inside `session/prompt` was reported as a clean turn,
    /// and nothing else in the suite could see it. That is the whole reason this test exists rather
    /// than a comment saying the absence is deliberate.
    @Test("a run whose response never arrived is distinguishable from one that ended")
    func aDiedMidTurnRunHasNoSummary() async throws {
        let logURL = try ACPRunnerTests.logURL("agentlog-crash")
        let run = try AgentRun.start(
            invocation: ACPRunnerTests.invocation(),
            agent: ACPRunnerTests.agent(
                mode: "crash",
                environment: ["FAKE_ACP_STDERR": "npx: could not determine executable to run"]
            ),
            logURL: logURL
        )
        let (killer, killerFired) = armKiller { run.session.transport.terminate() }
        defer { killer.cancel() }

        let (_, outcome) = await ACPRunnerTests.drain(run)
        let finished = try #require(outcome)

        #expect(finished.summary == nil)
        #expect(finished.exitCode == 9)
        // ⚠️ Where a failed `npx` resolution or a Node stack trace lands, and the only thing this
        // run has to say for itself. A crash that swallowed it would leave the card carrying a
        // failure with no reason attached.
        #expect(finished.stderr.contains("could not determine executable"))
        // And the log agrees with the caller — which is what makes the launch sweep's reading of a
        // run that died with the app the same reading this one gets live.
        #expect(AgentLog.lastSummary(inLogAt: logURL) == nil)

        killer.cancel()
        await killer.value
        #expect(!killerFired.value)
    }

    /// ⛔ The race Task 7's ordering rule exists to close, driven rather than reasoned about: an
    /// agent that exits the **instant** it answers still leaves its terminal line on disk.
    ///
    /// The tempting bug is closing the log handle from whichever of "the prompt returned" and "the
    /// child exited" happens first. `ClaudeRun` never had to think about it — it had one writer and
    /// closed after `waitForExit()` — and that argument does not transfer, because `AgentRun` writes
    /// `elliot/terminal` after `waitForExit()` has already returned. If the close wins,
    /// `AgentLog.lastSummary` answers `nil` with nothing anywhere saying why, and
    /// `RunScheduler.finish` degrades on every run rather than only a crashed one.
    ///
    /// `FAKE_ACP_EXIT_AFTER_REPLY` is what makes the window wide instead of theoretical: the double
    /// flushes the `session/prompt` response and exits in the same breath, so the child is gone
    /// before Elliot has written a byte of its own record.
    ///
    /// Break-tested by adding `writer.close()` immediately after `await transport.waitForExit()` —
    /// the close driven by the child's exit. Red here on both assertions, and red on three
    /// pre-existing tests that pin the same rule (`aTurnStreamsAndLogs`, and both of
    /// `PermissionPolicyTests`' log assertions). ⚠️ Note which assertion stayed **green**:
    /// `outcome?.summary?.stopReason`. The caller still had the verdict in memory while the file
    /// had nothing — the silent half, and the only half that survives a crash.
    @Test("the terminal line survives an agent that exits the moment it answers")
    func theTerminalLineIsNotLostToTheExit() async throws {
        let logURL = try ACPRunnerTests.logURL("agentlog-exit-race")
        let run = try AgentRun.start(
            invocation: ACPRunnerTests.invocation(),
            agent: ACPRunnerTests.agent(environment: ["FAKE_ACP_EXIT_AFTER_REPLY": "1"]),
            logURL: logURL
        )
        let (killer, killerFired) = armKiller { run.session.transport.terminate() }
        defer { killer.cancel() }

        let (_, outcome) = await ACPRunnerTests.drain(run)

        let objects = try ACPRunnerTests.objects(inLogAt: logURL)
        #expect(objects.allSatisfy { !$0.isEmpty })
        #expect(objects.compactMap { $0["method"] as? String }.last == AgentLog.terminalMethod)

        let found = try #require(AgentLog.lastSummary(inLogAt: logURL))
        #expect(found.stopReason == "end_turn")
        #expect(found.text == "Reading the file.")
        // The caller was handed the same thing the file kept.
        #expect(outcome?.summary?.stopReason == "end_turn")

        killer.cancel()
        await killer.value
        #expect(!killerFired.value)
    }
}
