import Foundation
import Testing
import TestSupport

@testable import ElliotProcess

/// What `AdapterHandshake.probe` records, asserted **on the probe** rather than through the two
/// Preflight rows it feeds.
///
/// ⛔ These exist because the rows alone were not enough, and that was measured rather than
/// supposed. `PreflightService.adapterCheck` now checks `sessionOpened` ahead of `failure`, so
/// smuggling an Elliot-authored sentence back into `AdapterProbe.failure` — the exact defect the
/// separation was introduced to fix — left the whole Preflight suite **green**: the bad sentence no
/// longer reaches the adapter row, and on the commands row it merely swapped one wording for
/// another that satisfies the same assertions. A guarantee defended only by the order of two
/// branches in a caller is one edit away from not being defended at all.
@Suite("Adapter probe")
struct AdapterProbeTests {
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ElliotProcessTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // ElliotKit
            .deletingLastPathComponent()  // repository root
    }

    static func agent(_ environment: [String: String] = [:]) -> ACPAgentProcess {
        ACPAgentProcess(
            executable: "/usr/bin/python3",
            arguments: [repositoryRoot.appendingPathComponent("Scripts/fake-acp.py").path],
            cwd: "/tmp",
            environment: environment
        )
    }

    /// Short enough not to spend the shipped two seconds in a test that is asserting a *carried
    /// value* rather than a duration. No race is possible: this double sends nothing at all, so
    /// there is no notification for a shorter window to lose.
    static let window: Duration = .milliseconds(250)

    /// ⛔ The separation itself, at the source. `failure` is what `adapterCheck` prints **verbatim
    /// as the adapter's own verdict on itself**; the commands window running out is Elliot's own
    /// account of its own patience on a different question. Writing the second into the first is
    /// what made a healthy adapter render as `.fail` under *"Nothing will run until it does."*
    @Test("a session that advertises nothing records Elliot's window, and no failure at all")
    func aQuietAdapterRecordsNoFailure() async {
        // No FAKE_ACP_COMMANDS: the double opens a session and never sends the notification.
        let probe = await AdapterHandshake.probe(agent: Self.agent(), commandsWindow: Self.window)

        #expect(probe.sessionOpened)
        #expect(probe.namedItself)
        // Never established, and never `[]` — the two-valued answer this file's neighbours catalogue.
        #expect(probe.commands == nil)
        #expect(probe.failure == nil)
        #expect(probe.quietCommands == Self.window)
    }

    /// `InitializeResponse.agentInfo` is `AgentInfo?`, so this adapter is legal rather than broken —
    /// and every other knob on the double leaves `agentInfo` in place, which is why the case had no
    /// witness until it had cost a false failing row.
    @Test("an adapter that never names itself still records the session it opened")
    func anAnonymousAdapterStillRecordsItsSession() async {
        let probe = await AdapterHandshake.probe(
            agent: Self.agent(["FAKE_ACP_NO_AGENT_INFO": "1"]), commandsWindow: Self.window)

        #expect(!probe.namedItself)
        #expect(probe.agentName == nil)
        #expect(probe.agentVersion == nil)
        // ⛔ The two facts that must not be inferred from one another.
        #expect(probe.sessionOpened)
        #expect(probe.failure == nil)
    }

    /// ⛔ **Two silences, and only one of them is a wait Elliot actually made.** An adapter that
    /// opens a session and goes away advertises nothing in no measurable time; recording the window
    /// here would put *"advertised nothing within 2 seconds"* on screen for a wait that never
    /// happened. Setting `quietCommands` on `commands == nil` alone — dropping the `windowClosed`
    /// condition — was a **green break** across both suites until this test existed.
    @Test("an adapter that opens a session and goes away leaves no window behind either")
    func aDepartedAdapterRecordsNoWindow() async {
        let probe = await AdapterHandshake.probe(
            agent: Self.agent(["FAKE_ACP_EXIT_AFTER_SESSION": "1"]), commandsWindow: Self.window)

        #expect(probe.sessionOpened)
        #expect(probe.commands == nil)
        #expect(probe.failure == nil)
        // The window is not what ended this wait, so there is no window to report.
        #expect(probe.quietCommands == nil)
    }

    /// The other side of `quietCommands`: when the notification arrives there is no window to
    /// report, and a probe that recorded one anyway would be quoting a wait it never made.
    @Test("commands that arrive leave no window behind")
    func advertisedCommandsLeaveNoWindow() async throws {
        let path = "/private/tmp/adapter-probe-commands-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data(#"[{"name": "ai-migration-kit:merge-pr", "description": "z"}]"#.utf8)
            .write(to: URL(fileURLWithPath: path))

        // The shipped window, deliberately: this one *is* waiting for something, and shortening it
        // would be racing the double instead of bounding it. It returns the moment the
        // notification lands.
        let probe = await AdapterHandshake.probe(agent: Self.agent(["FAKE_ACP_COMMANDS": path]))

        #expect(probe.commands == ["ai-migration-kit:merge-pr"])
        #expect(probe.sessionOpened)
        #expect(probe.failure == nil)
        #expect(probe.quietCommands == nil)
    }

    /// And the case that really is a failure keeps saying so, in the system's own words, with
    /// nothing claimed about a session that never opened.
    @Test("a refusal before the spawn is a failure, and opens no session")
    func anUnresolvedAdapterFails() async {
        let probe = await AdapterHandshake.probe(
            agent: ACPAgentProcess(executable: "", arguments: [], cwd: "/tmp", environment: [:]))

        #expect(!probe.sessionOpened)
        #expect(!probe.namedItself)
        #expect(probe.commands == nil)
        #expect(probe.quietCommands == nil)
        #expect(probe.failure == .error(AgentInvocationError.adapterNotResolved.localizedDescription))
    }
}
