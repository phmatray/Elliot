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

    @Test("a request whose options contain no allow choice is declined, not guessed at")
    func unknownOptionSetDeclines() async throws {
        let policy = PermissionPolicy(mode: .bypassPermissions)
        let request = RequestPermissionRequest(
            options: [],
            sessionId: SessionId("sess-fake-0001"),
            toolCall: ToolCallUpdate(toolCallId: "tc-1", title: "Bash")
        )

        let response = try await policy.handlePermissionRequest(request: request)

        // `PermissionOutcome(cancelled: true)` — never an option this policy was not actually
        // offered, and never "the first option" just because one existed.
        #expect(response.outcome.outcome == "cancelled")
        #expect(response.outcome.optionId == nil)
        #expect(policy.refusals() == ["Bash"])
    }
}
