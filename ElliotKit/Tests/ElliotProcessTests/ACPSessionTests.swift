import ACP
import ACPModel
import Foundation
import Testing
import TestSupport

@testable import ElliotProcess

/// The whole of Stage 0, end to end: a real child process, real JSON-RPC framing, a real
/// request/response correlation, and a real notification stream — with a double standing in for
/// the agent so the suite stays deterministic and needs no network, no tokens and no GitHub.
@Suite("ACP session")
struct ACPSessionTests {
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ElliotProcessTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // ElliotKit
            .deletingLastPathComponent()  // repository root
    }

    static func agent(mode: String = "ok") -> ACPAgentProcess {
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

    /// `fs`/`terminal` are the only non-optional fields on `ClientCapabilities` — every caller of
    /// `initialize` has to build one regardless of what the test actually exercises. Mirrors the
    /// loopback test's capabilities in `ACPClientTransportTests.swift`.
    static let capabilities = ClientCapabilities(
        fs: FileSystemCapabilities(readTextFile: false, writeTextFile: false),
        terminal: false
    )

    @Test("a full turn: initialize, new session, set the mode, prompt, collect updates")
    func fullTurn() async throws {
        let transport = try ACPTransport(Self.agent())
        let client = Client(transport: transport)
        // Armed here so it covers every wait below, including `initialize`/`newSession`/
        // `setConfigOption` — see `armKiller`'s doc comment (`TestSupport/ArmedKiller.swift`).
        // Cancelled only once every wait it guards has actually finished, so the kill fires for
        // any one of them running long, and never on a successful run.
        let (killer, killerFired) = armKiller { transport.terminate() }
        defer { killer.cancel() }
        defer { transport.terminate() }

        let updates = Task {
            var collected: [SessionUpdateNotification] = []
            for await notification in await client.notifications {
                guard notification.method == "session/update" else { continue }
                collected.append(
                    try! JSONDecoder().decode(
                        SessionUpdateNotification.self,
                        from: JSONEncoder().encode(notification.params)
                    ))
                if collected.count == 8 { break }  // 1 mode + 7 fixture frames
            }
            return collected
        }

        let initialize = try await withTimeout(.seconds(10)) {
            try await client.initialize(protocolVersion: 1, capabilities: Self.capabilities)
        }
        #expect(initialize.agentInfo?.name == "fake-acp")

        let session = try await withTimeout(.seconds(10)) {
            try await client.newSession(workingDirectory: "/tmp", mcpServers: [])
        }
        #expect(session.sessionId.value == "sess-fake-0001")

        _ = try await withTimeout(.seconds(10)) {
            try await client.setConfigOption(
                sessionId: session.sessionId,
                configId: SessionConfigId("mode"),
                value: SessionConfigValueId("bypassPermissions")
            )
        }

        let prompt = try await client.sendPrompt(
            sessionId: session.sessionId, content: [.text(TextContent(text: "go"))]
        )
        #expect(prompt.stopReason == .endTurn)

        let collected = await updates.value
        // Detects a SHORT stream only: the collector breaks at exactly 8, so a 9th notification
        // arriving before this line is never read and this count would not see it. Over-delivery
        // is not a claim this assertion makes.
        #expect(collected.count == 8)

        // Proof, not prose, that `killer` did not fire. Cancellation is cooperative — `.cancel()`
        // alone proves nothing about a task not yet scheduled to observe it — so this cancels and
        // waits for `killer`'s body to actually finish before reading `killerFired`. See
        // `armKiller`'s doc comment for why the flag, not `transport.isConnected`, is the check.
        killer.cancel()
        await killer.value
        #expect(!killerFired.value)
    }

    /// A single projection over the two distinct wire shapes a tool call arrives as. Upstream
    /// models creation (`ToolCallUpdate`, from a `"tool_call"` frame) and update
    /// (`ToolCallUpdateDetails`, from a `"tool_call_update"` frame) as two separate types rather
    /// than one — so this is what "collapse the switch accordingly" resolves to: a common shape
    /// the assertions below can read regardless of which case produced a given frame, with
    /// `content` kept optional on both sides (`ToolCallUpdate.content` is not optional upstream;
    /// `ToolCallUpdateDetails.content` is) so a creation frame and a patch frame are directly
    /// comparable.
    private struct ToolCallFrame {
        let title: String?
        let kind: ToolKind?
        let status: ToolStatus?
        let locations: [ToolLocation]?
        let content: [ToolCallContent]?
    }

    /// The shape the design's §5.1 calls out, pinned against the double rather than described.
    ///
    /// Four frames for one tool call, three of which omit a field an earlier one carried. What
    /// this test actually pins is the **wire contract**: those absences are real absences on the
    /// wire — `JSONRPCNotification.params` is `AnyCodable?`, so a field a frame never sent decodes
    /// as `nil` here, not as a default — and they survive the round trip through `AnyCodable`
    /// intact. A future fold has to satisfy that contract, or this test's decode-level assertions
    /// fail before the fold is even reached.
    ///
    /// ⚠️ It does **not** pin merge semantics, and nothing in this repository does yet: Stage 0
    /// deliberately builds no `RunEvent`/fold, `grep -rn "toolCallId\|ToolCallUpdate"
    /// ElliotKit/Sources/` returns nothing, and a replacing fold written tomorrow would ship green
    /// past this test — it has no fold to catch. The claim here is narrower and still real: when
    /// that fold exists, its own test can trust that a frame's absent fields are absent *on the
    /// wire*, not smuggled in by this test's own decoding.
    @Test("one tool call arrives as four frames, each carrying only what changed")
    func toolCallPatchesArrivePartial() async throws {
        let transport = try ACPTransport(Self.agent())
        let client = Client(transport: transport)
        // Armed here so it covers every wait below, including `initialize`/`newSession` — see
        // `armKiller`'s doc comment (`TestSupport/ArmedKiller.swift`).
        let (killer, killerFired) = armKiller { transport.terminate() }
        defer { killer.cancel() }
        defer { transport.terminate() }

        let frames = Task { () -> [ToolCallFrame] in
            var collected: [ToolCallFrame] = []
            for await notification in await client.notifications {
                guard notification.method == "session/update" else { continue }
                let note = try! JSONDecoder().decode(
                    SessionUpdateNotification.self,
                    from: JSONEncoder().encode(notification.params)
                )
                switch note.update {
                case .toolCall(let call) where call.toolCallId == "tc-1":
                    collected.append(
                        ToolCallFrame(
                            title: call.title, kind: call.kind, status: call.status,
                            locations: call.locations, content: call.content
                        ))
                case .toolCallUpdate(let call) where call.toolCallId == "tc-1":
                    collected.append(
                        ToolCallFrame(
                            title: call.title, kind: call.kind, status: call.status,
                            locations: call.locations, content: call.content
                        ))
                default:
                    continue
                }
                if collected.count == 4 { break }
            }
            return collected
        }

        _ = try await withTimeout(.seconds(10)) {
            try await client.initialize(protocolVersion: 1, capabilities: Self.capabilities)
        }
        let session = try await withTimeout(.seconds(10)) {
            try await client.newSession(workingDirectory: "/tmp", mcpServers: [])
        }

        _ = try await client.sendPrompt(
            sessionId: session.sessionId, content: [.text(TextContent(text: "go"))]
        )

        let collected = await frames.value
        // Detects a SHORT stream only — see the identical note in `fullTurn`. The collector
        // breaks at exactly 4, so a 5th frame for "tc-1" arriving before this line is never read.
        #expect(collected.count == 4)

        // Frame 1 creates it: a generic title, a kind, a status.
        #expect(collected[0].title == "Edit")
        #expect(collected[0].kind == .edit)
        #expect(collected[0].status == .pending)

        // Frame 2 refines the title and adds a location — and carries NO status.
        #expect(collected[1].title == "Edit /tmp/notes.txt")
        #expect(collected[1].locations?.first?.path == "/tmp/notes.txt")
        #expect(collected[1].status == nil)

        // Frame 3 is content only. Every other field is absent, which is the trap.
        #expect(collected[2].title == nil)
        #expect(collected[2].kind == nil)
        #expect(collected[2].status == nil)
        #expect(collected[2].content?.isEmpty == false)

        // Frame 4 completes it, and carries nothing else at all.
        #expect(collected[3].status == .completed)
        #expect(collected[3].title == nil)
        #expect(collected[3].kind == nil)

        // Proof `killer` did not fire on this successful run — see `fullTurn`'s identical check
        // and `armKiller`'s doc comment for why cancelling alone would not prove it.
        killer.cancel()
        await killer.value
        #expect(!killerFired.value)
    }
}
