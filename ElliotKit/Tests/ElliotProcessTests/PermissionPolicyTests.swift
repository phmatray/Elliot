import ACP
import ACPModel
import ElliotModel
import Foundation
import Testing
import TestSupport

@testable import ElliotProcess

/// Whether a client whose delegate is `PermissionPolicy` answers `session/request_permission`
/// correctly, against `Scripts/fake-acp.py`'s `FAKE_ACP_MODE=permission` — the one mode that
/// genuinely gates: it fires the request and **blocks on stdin** for the matching answer before
/// doing anything else, so a policy that answers correctly and one that does not produce visibly
/// different turns. Driven the same way `ACPSessionTests` drives a turn — a real child, a real
/// handshake, a real `session/prompt` — because the claim under test is what a *client* does with
/// the answer, not just what `PermissionPolicy` returns in isolation.
@Suite("Permission policy")
struct PermissionPolicyTests {
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ElliotProcessTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // ElliotKit
            .deletingLastPathComponent()  // repository root
    }

    /// The same `ACPAgentProcess` shape `ACPSessionTests.agent(mode:)` builds, defaulted to the
    /// one mode this suite is actually about.
    static func agent(mode: String = "permission") -> ACPAgentProcess {
        ACPAgentProcess(
            executable: "/usr/bin/python3",
            arguments: [repositoryRoot.appendingPathComponent("Scripts/fake-acp.py").path],
            cwd: "/tmp",
            environment: [
                "FAKE_ACP_MODE": mode,
                "FAKE_ACP_FIXTURE": repositoryRoot
                    .appendingPathComponent("Fixtures/acp/fake-simple-turn.json").path,
            ]
        )
    }

    static let capabilities = ClientCapabilities(
        fs: FileSystemCapabilities(readTextFile: false, writeTextFile: false),
        terminal: false
    )

    @Test("at bypassPermissions the policy allows, and the turn completes")
    func bypassAllows() async throws {
        let transport = try ACPTransport(Self.agent())
        let client = Client(transport: transport)
        // Armed here so it covers every wait below — see `armKiller`'s doc comment
        // (`TestSupport/ArmedKiller.swift`) for why none of `initialize`/`newSession`/
        // `sendPrompt` can be bounded any other way.
        let (killer, killerFired) = armKiller { transport.terminate() }
        defer { killer.cancel() }
        defer { transport.terminate() }

        let policy = PermissionPolicy(mode: .bypassPermissions)
        // Before the handshake even starts — well ahead of `sendPrompt`, which is the only
        // requirement, but the earliest point is also the simplest one to get right.
        await client.setDelegate(policy)

        let frames = Task { () -> [SessionUpdate] in
            var collected: [SessionUpdate] = []
            for await notification in await client.notifications {
                guard notification.method == "session/update" else { continue }
                let note = try! JSONDecoder().decode(
                    SessionUpdateNotification.self,
                    from: JSONEncoder().encode(notification.params)
                )
                collected.append(note.update)
                if collected.count == 7 { break }  // the whole of fake-simple-turn.json
            }
            return collected
        }

        _ = try await withTimeout(.seconds(10)) {
            try await client.initialize(protocolVersion: 1, capabilities: Self.capabilities)
        }
        let session = try await withTimeout(.seconds(10)) {
            try await client.newSession(workingDirectory: "/tmp", mcpServers: [])
        }

        let prompt = try await client.sendPrompt(
            sessionId: session.sessionId, content: [.text(TextContent(text: "go"))]
        )

        // The fixture's frames arrived — the double only replays them once the permission
        // request has been answered `allow` — and the turn ended on its own word, not a refusal.
        let collected = await frames.value
        #expect(collected.count == 7)
        #expect(prompt.stopReason == .endTurn)

        // The whole point of `bypassPermissions`: nothing was declined.
        #expect(policy.refusals().isEmpty)

        killer.cancel()
        await killer.value
        #expect(!killerFired.value)
    }

    @Test("under a tighter mode the policy declines, and the refusal is recorded")
    func tighterModesDecline() async throws {
        let transport = try ACPTransport(Self.agent())
        let client = Client(transport: transport)
        let (killer, killerFired) = armKiller { transport.terminate() }
        defer { killer.cancel() }
        defer { transport.terminate() }

        let policy = PermissionPolicy(mode: .acceptEdits)
        await client.setDelegate(policy)

        // No fixture frame may arrive: the double skips the fixture entirely on any answer that
        // is not `allow`, so a single frame landing here would mean the policy granted something
        // it should have declined.
        let sawAFrame = Task { () -> Bool in
            for await notification in await client.notifications {
                if notification.method == "session/update" { return true }
            }
            return false
        }

        _ = try await withTimeout(.seconds(10)) {
            try await client.initialize(protocolVersion: 1, capabilities: Self.capabilities)
        }
        let session = try await withTimeout(.seconds(10)) {
            try await client.newSession(workingDirectory: "/tmp", mcpServers: [])
        }

        let prompt = try await client.sendPrompt(
            sessionId: session.sessionId, content: [.text(TextContent(text: "go"))]
        )

        #expect(prompt.stopReason == .refusal)
        // `Scripts/fake-acp.py`'s MODE=permission request carries no `title` and no `_meta`, only
        // `toolCallId: "tc-1"` — so the recorded name falls all the way to the id, exercising the
        // fallback rather than the common case `AgentRun.summary`'s denial naming already covers.
        #expect(policy.refusals() == ["tc-1"])

        // Ending the transport is what lets `frames` resolve at all (its `for await` would
        // otherwise wait on a notification stream nothing will ever populate again).
        transport.terminate()
        #expect(await sawAFrame.value == false)

        killer.cancel()
        await killer.value
        #expect(!killerFired.value)
    }

    /// A permission request carrying whatever options a case wants to offer, otherwise shaped like
    /// the one `Scripts/fake-acp.py` sends.
    static func request(options: [PermissionOption]) -> RequestPermissionRequest {
        RequestPermissionRequest(
            options: options,
            sessionId: SessionId("sess-fake-0001"),
            toolCall: ToolCallUpdate(toolCallId: "tc-1", title: "Bash")
        )
    }

    @Test("a request whose options contain no allow choice is declined, not guessed at")
    func unknownOptionSetDeclines() async throws {
        let policy = PermissionPolicy(mode: .bypassPermissions)

        let response = try await policy.handlePermissionRequest(request: Self.request(options: []))

        // `PermissionOutcome(cancelled: true)` — never an option this policy was not actually
        // offered, and never "the first option" just because one existed.
        #expect(response.outcome.outcome == "cancelled")
        #expect(response.outcome.optionId == nil)
        #expect(policy.refusals() == ["Bash"])
    }

    // MARK: - Never "the first option"
    //
    // ⛔ The three below exist because `unknownOptionSetDeclines` **cannot fail** for the defect
    // the class header calls its central safety claim: "it never falls back to 'the first option',
    // which is how a policy would silently allow something it was never actually asked about."
    // Measured — replacing the option lookup with `first(where: …) ?? request.options.first`,
    // literally guessing, leaves all three of this suite's original tests green
    // (`Test run with 3 tests in 1 suite passed`). `options: []` is the degenerate case where
    // `first(where:)` and `first` are both `nil`, so declining and guessing are indistinguishable
    // there. Each case below offers exactly one option **of the wrong kind**, which is where the
    // two answers part.

    @Test("offered only a reject option, bypassPermissions declines rather than selecting it")
    func bypassNeverSelectsARejectOption() async throws {
        let policy = PermissionPolicy(mode: .bypassPermissions)
        let response = try await policy.handlePermissionRequest(
            request: Self.request(options: [
                PermissionOption(kind: "reject_once", name: "Deny", optionId: "deny")
            ]))

        // Selecting `deny` here would be *safe* and still wrong: this policy answers by kind, and
        // an answer it was not asked for is a guess whichever direction it points.
        #expect(response.outcome.outcome == "cancelled")
        #expect(response.outcome.optionId == nil)
        #expect(policy.refusals() == ["Bash"])
    }

    @Test("offered only an allow option, a tighter mode declines rather than selecting it")
    func tighterModeNeverSelectsAnAllowOption() async throws {
        // The consequential direction, and the reason this mirror case is not symmetry for its own
        // sake: `PermissionMode.appraisal(repo:)` returns `.acceptEdits` for every appraisal run,
        // so a guess here grants a real tool call in a real checkout under the one mode whose whole
        // purpose is that it does not.
        let policy = PermissionPolicy(mode: .acceptEdits)
        let response = try await policy.handlePermissionRequest(
            request: Self.request(options: [
                PermissionOption(kind: "allow_once", name: "Allow", optionId: "allow")
            ]))

        #expect(response.outcome.outcome == "cancelled")
        #expect(response.outcome.optionId == nil)
        #expect(policy.refusals() == ["Bash"])
    }

    @Test("an option kind this build has never seen is not selected either")
    func unrecognisedKindIsNotSelected() async throws {
        // `allow_for_session` is not one of `PermissionDecision`'s four cases. A future adapter
        // that offers only kinds this build does not know must get a decline, not the nearest
        // plausible-looking thing — the same instinct as `RunEvent.unreadable`, which degrades one
        // row rather than guessing at what a schema it has not seen meant.
        let policy = PermissionPolicy(mode: .bypassPermissions)
        let response = try await policy.handlePermissionRequest(
            request: Self.request(options: [
                PermissionOption(kind: "allow_for_session", name: "Allow", optionId: "allow")
            ]))

        #expect(response.outcome.outcome == "cancelled")
        #expect(response.outcome.optionId == nil)
        #expect(policy.refusals() == ["Bash"])
    }

    // MARK: - What a real run does
    //
    // ⛔ Everything above constructs its own `Client` and calls `setDelegate` itself, so it proves
    // `PermissionPolicy` answers correctly and proves **nothing** about `AgentRun` ever installing
    // it. Measured — replacing `await client.setDelegate(policy)` in `AgentRun.start` with
    // `_ = policy` left the whole suite green (`Test run with 2846 tests in 336 suites passed`),
    // which would return every real run to the stall the class header says this policy exists to
    // prevent. The two below drive `AgentRun.start` itself, so that line is load-bearing.
    //
    // ⚠️ Against this double the delegate's absence surfaces as a **refusal**, not a hang:
    // `Client.handleIncomingRequest` catches `ClientError.delegateNotSet` and replies `-32603`
    // (`Vendor/swift-acp/ACP/Client.swift:1161-1181`), and `fake-acp.py` treats an error reply the
    // same as `deny` — it skips the fixture and answers `stopReason: "refusal"`. So the assertions
    // here are on the turn's own word rather than on a timeout, and neither test depends on the
    // hang the brief describes for a real adapter.
    //
    // The run/log helpers come from `ACPRunnerTests` rather than being copied: four helpers
    // written twice is the shape #146 is about, and `logURL`/`objects`/`drain` are exactly the
    // pieces that would drift.

    @Test("a real run installs the policy, so a gated turn completes on its own word")
    func aRunInstallsThePolicy() async throws {
        let logURL = try ACPRunnerTests.logURL("acp-permission-allow")
        let run = try AgentRun.start(
            invocation: ACPRunnerTests.invocation(permissionMode: .bypassPermissions),
            agent: Self.agent(),
            logURL: logURL
        )
        // Armed for `armKiller`'s stated reason: every `Client` request this run makes reaches
        // `sendRequest(…, timeout: nil)`, which no `withTimeout` can bound.
        let (killer, killerFired) = armKiller { run.session.transport.terminate() }
        defer { killer.cancel() }

        let (_, outcome) = await ACPRunnerTests.drain(run)

        // `end_turn` is reachable only through an `allow` answer — the double blocks on stdin for
        // it and skips the fixture entirely on anything else.
        #expect(outcome?.summary?.stopReason == "end_turn")
        #expect(outcome?.summary?.isError == false)

        // ⛔ Asserted on the log, never on `updates`: that stream is `bufferingNewest(512)` and
        // deliberately lossy (#128). Eight, not seven — the double emits a `current_mode_update` of
        // its own while answering `session/set_config_option`, on top of the fixture's seven.
        let objects = try ACPRunnerTests.objects(inLogAt: logURL)
        let methods = objects.compactMap { $0["method"] as? String }
        #expect(methods.filter { $0 == "session/update" }.count == 8)

        // Nothing was declined, so the log carries no refusal record at all — the empty list is
        // deliberately not written, so its absence is the assertion.
        #expect(!methods.contains(AgentLog.refusalsMethod))
        #expect(methods.last == AgentLog.terminalMethod)

        killer.cancel()
        await killer.value
        #expect(!killerFired.value)
    }

    @Test("a refused request is named in the run's own log")
    func aRefusalIsNamedInTheLog() async throws {
        let logURL = try ACPRunnerTests.logURL("acp-permission-refuse")
        let run = try AgentRun.start(
            invocation: ACPRunnerTests.invocation(permissionMode: .acceptEdits),
            agent: Self.agent(),
            logURL: logURL
        )
        let (killer, killerFired) = armKiller { run.session.transport.terminate() }
        defer { killer.cancel() }

        let (_, outcome) = await ACPRunnerTests.drain(run)

        #expect(outcome?.summary?.stopReason == "refusal")

        let objects = try ACPRunnerTests.objects(inLogAt: logURL)
        let methods = objects.compactMap { $0["method"] as? String }

        // The point of the whole ledger: `refusals()` reached the log, naming what was refused.
        // `fake-acp.py`'s request carries no `title` and no `_meta`, only `toolCallId: "tc-1"`, so
        // the recorded name falls all the way to the id — the fallback rather than the common case.
        let record = try #require(
            objects.first { $0["method"] as? String == AgentLog.refusalsMethod })
        let params = try #require(record["params"] as? [String: Any])
        #expect(params["toolNames"] as? [String] == ["tc-1"])

        // ⛔ The ordering the record has to respect: `elliot/terminal` stays the log's last line,
        // because that is what `AgentLog.lastSummary`'s backwards scan (Task 9) hunts for.
        #expect(methods.last == AgentLog.terminalMethod)
        let refusalIndex = try #require(methods.firstIndex(of: AgentLog.refusalsMethod))
        #expect(refusalIndex < methods.count - 1)

        // The fixture never played: the only `session/update` is the double's own mode echo, so
        // nothing the policy declined ran anyway.
        #expect(methods.filter { $0 == "session/update" }.count == 1)

        killer.cancel()
        await killer.value
        #expect(!killerFired.value)
    }
}
