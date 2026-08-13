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

    /// `sendPrompt` is the one call in this suite `withTimeout` cannot bound.
    ///
    /// `Client.sendPrompt` reaches `sendRequest(..., timeout: nil)`, which suspends on a bare
    /// `withCheckedThrowingContinuation` stored in `pendingRequests` — nothing about it observes
    /// cancellation. Wrapping that in `withTimeout` does not help: `withThrowingTaskGroup` is a
    /// structured-concurrency scope, and a scope cannot exit while a child task is still running,
    /// cancelled or not — `group.cancelAll()` asks, it does not evict. Under `FAKE_ACP_MODE=hang`
    /// the double never answers, so that child never finishes, and the wrapped call is stuck for
    /// as long as the process lives. Measured directly: a 20 s `withTimeout` around this exact call
    /// was still alive at 10m51s, holding the SwiftPM build lock the whole time.
    ///
    /// The only thing that actually ends a stuck turn is ending the *agent* — `terminate()`
    /// (`ACPTransport.swift:141`, its first caller anywhere in this package) kills the child,
    /// which closes its stdout, which finishes `transport.messages`, which ends `Client`'s read
    /// loop, which fails every still-pending request through `handleTermination()`. That is what
    /// makes `sendPrompt` throw instead of hang. `killer` arms exactly that on a deadline, and is
    /// cancelled the moment a real reply arrives — the SIGTERM never fires on the happy path.
    private func sendPromptOrKill(
        client: Client,
        transport: ACPTransport,
        sessionId: SessionId,
        deadline: Duration = .seconds(20)
    ) async throws -> SessionPromptResponse {
        let killer = Task {
            try? await Task.sleep(for: deadline)
            transport.terminate()
        }
        defer { killer.cancel() }
        return try await client.sendPrompt(
            sessionId: sessionId, content: [.text(TextContent(text: "go"))]
        )
    }

    @Test("a full turn: initialize, new session, set the mode, prompt, collect updates")
    func fullTurn() async throws {
        let transport = try ACPTransport(Self.agent())
        let client = Client(transport: transport)
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

        let prompt = try await sendPromptOrKill(
            client: client, transport: transport, sessionId: session.sessionId
        )
        #expect(prompt.stopReason == .endTurn)

        let collected = try await withTimeout(.seconds(10)) { await updates.value }
        #expect(collected.count == 8)
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
    /// Four frames for one tool call, three of which omit a field an earlier one carried. A fold
    /// that *replaces* the row instead of merging it would finish with no title and no kind — and
    /// this is the test that would not let that ship.
    @Test("one tool call arrives as four frames, each carrying only what changed")
    func toolCallPatchesArrivePartial() async throws {
        let transport = try ACPTransport(Self.agent())
        let client = Client(transport: transport)
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
        _ = try await sendPromptOrKill(
            client: client, transport: transport, sessionId: session.sessionId
        )

        let collected = try await withTimeout(.seconds(10)) { await frames.value }
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
    }
}
