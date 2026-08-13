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

    /// Arms a deadline that ends `transport` unless cancelled first — armed right after `client`
    /// exists, so it is the one mechanism able to bound *every* wait that follows: `initialize`,
    /// `newSession` and `setConfigOption` reach the identical unguarded `sendRequest(...,
    /// timeout: nil)` that `sendPrompt` does, so they need this exactly as much. See
    /// `AsyncTimeout.swift`'s doc comment for why `withTimeout` cannot bound any of them on its
    /// own — this exists because that guarantee does not hold.
    ///
    /// None of those waits can be bounded the ways that look obvious:
    /// - Every `Client` request above reaches `sendRequest(..., timeout: nil)`, which suspends on
    ///   a bare `withCheckedThrowingContinuation` — nothing about it observes cancellation.
    ///   Wrapping one in `withTimeout` does not help: `withThrowingTaskGroup` is a
    ///   structured-concurrency scope, and a scope cannot exit while a child task is still
    ///   running, cancelled or not — `group.cancelAll()` asks, it does not evict.
    /// - The notification collector below is a plain `Task<[T], Never>` — non-throwing, so
    ///   `.value` is `get async`, not `get async throws`, and cannot even signal cancellation.
    ///   `withTimeout` around `await updates.value` is exactly as broken as around `sendPrompt`,
    ///   for the identical reason, and was the second Critical this file shipped with once.
    ///
    /// The only thing that actually ends any of them is ending the *agent*: `terminate()`
    /// (`ACPTransport.swift:141`, its first caller anywhere in this package) kills the child, which
    /// closes its stdout, which finishes `transport.messages`, which ends `Client`'s read loop,
    /// which fails every still-pending request through `handleTermination()` **and** finishes the
    /// notification stream — so a stuck `sendPrompt` throws, and a short-of-N collector returns
    /// with fewer than it wanted, instead of either one hanging. Break-tested: pointed a copy of
    /// `fullTurn` at a 2-frame fixture (short of the 8 the collector wants) with a 3 s deadline —
    /// it **failed** at 3.06 s on `collected.count == 8`, not a hang, which is what this whole
    /// mechanism exists to guarantee for the notification-collection half.
    ///
    /// ⛔ The sleep below is deliberately **not** `try? await Task.sleep(...)` followed by an
    /// unconditional `transport.terminate()`. That was this file's first Critical: `try?` swallows
    /// `Task.sleep`'s `CancellationError` and execution falls straight through to `terminate()`
    /// regardless of *why* the sleep ended — so `killer.cancel()` did not disarm the kill, it
    /// **triggered** it, within milliseconds of every successful call (reviewer's own standalone
    /// probe: cancel at 0.05 s, `terminate()` at 0.06 s). Both tests still passed, correctly by
    /// accident — the double writes every `session/update` line before its `session/prompt`
    /// reply, so a collector reading an already-finished stream still drains a full buffer.
    ///
    /// `fired` is the proof that this version does not repeat that, and it is read-only outside
    /// this file — production has no need of it. ⚠️ It does **not** read `transport.isConnected`
    /// for the proof, and getting to that took two wrong attempts, both measured directly against
    /// the reintroduced buggy body above:
    /// 1. `#expect(await transport.isConnected)` placed where `defer { killer.cancel() }` was the
    ///    only cancellation — passed even with the bug present, because the check ran before the
    ///    function returned, i.e. before `defer` had cancelled anything at all. Not a race, simply
    ///    the wrong order.
    /// 2. `killer.cancel(); await killer.value; #expect(await transport.isConnected)` — still
    ///    passed with the bug present. Killing a process is inherently asynchronous (SIGTERM → the
    ///    child's own handler → the kernel reaping it → `Process`'s termination handler updating
    ///    `isRunning`), so `isConnected` read immediately after `terminate()` was *called* is its
    ///    own race, one layer below the Swift-cancellation race this helper exists to close — the
    ///    child had not finished dying yet by the time the check ran.
    ///
    /// `fired` closes both gaps: it is set synchronously, in the same task whose completion the
    /// caller already awaits, so there is nothing left to race. Reintroducing the buggy body a
    /// third time, with this check, failed both tests immediately and correctly.
    private func armKiller(_ transport: ACPTransport, deadline: Duration = .seconds(20)) -> (
        killer: Task<Void, Never>, fired: Locked<Bool>
    ) {
        let fired = Locked(false)
        let killer = Task {
            do {
                try await Task.sleep(for: deadline)
            } catch {
                return  // cancelled — a real reply or a full collection arrived first
            }
            fired.withLock { $0 = true }
            transport.terminate()
        }
        return (killer, fired)
    }

    @Test("a full turn: initialize, new session, set the mode, prompt, collect updates")
    func fullTurn() async throws {
        let transport = try ACPTransport(Self.agent())
        let client = Client(transport: transport)
        // Armed here so it covers every wait below, including `initialize`/`newSession`/
        // `setConfigOption` — see `armKiller`'s doc comment. Cancelled only once every wait it
        // guards has actually finished, so the kill fires for any one of them running long, and
        // never on a successful run.
        let (killer, killerFired) = armKiller(transport)
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
        // `armKiller`'s doc comment.
        let (killer, killerFired) = armKiller(transport)
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
