import ACP
import ACPModel
import Foundation
import Testing
import TestSupport

@testable import ElliotProcess

/// #381 from the outside: after the owner is gone, no child survives.
///
/// ⛔ **The child must be one that survives its stdin closing, and `/bin/cat` is not.** An
/// earlier draft of this plan asserted that `cat` "reads stdin, writes stdout, and stays alive
/// on an empty pipe". Measured on this machine, 2026-08-13: spawned with a pipe on stdin,
/// alive before the close, **exit code 0 within 0.05 s of `p.stdin.close()`**. `cat` reads to
/// EOF and exits — which is exactly what `ACPTransport.close()` produces
/// (`ACPTransport.swift:126-129` → `ChildProcess.closeStdin()`). So `close()` alone ends it,
/// the escalation never fires, and Step 7's break-test would leave the whole suite **green**
/// with the escalation commented out: a break that changes no behaviour reads as a pass.
///
/// `FAKE_ACP_MODE=hang` is no better for this: `fake-acp.py`'s main loop is
/// `while True: read_message(STDIN)` and `break`s on `None`, so it too exits on EOF.
///
/// The two children below are chosen for the two rungs of the escalation, and neither reads
/// stdin at all:
/// - `deafAgent()` — `/bin/sleep 600`. Ignores the stdin close; **dies on SIGTERM**. This is
///   the rung `transport.terminate(hardKillAfter:)` reaches first.
/// - `stubbornAgent()` — `/bin/sh -c 'trap "" TERM; exec sleep 600'`. Ignores the stdin close
///   **and** SIGTERM, so only the SIGKILL follow-up ends it. `ProcessTermination.hardKillGrace`
///   is `.seconds(15)`, so this test passes a shorter grace explicitly rather than waiting it
///   out — and asserts on "gone by the deadline", never on how long it took.
///
/// ⚠️ `trap "" TERM` is inherited across `exec`, which is why the `sh -c` form works and a bare
/// `sleep` does not. Confirm the stubborn child really is stubborn before trusting a green run
/// here: `kill -TERM <pid>` on it must leave it alive.
@Suite("Agent session lifetime")
struct AgentSessionLifetimeTests {
    static func deafAgent() -> ACPAgentProcess {
        ACPAgentProcess(executable: "/bin/sleep", arguments: ["600"], cwd: "/tmp", environment: [:])
    }

    static func stubbornAgent() -> ACPAgentProcess {
        ACPAgentProcess(
            executable: "/bin/sh", arguments: ["-c", #"trap "" TERM; exec sleep 600"#],
            cwd: "/tmp", environment: [:])
    }

    /// Every session here uses short graces. A child that ignores its stdin closing sits out
    /// the whole flush window on *each* of these tests, so the shipped two seconds would cost
    /// this one suite about eight — against a full run that executes the whole suite in seconds.
    /// ⛔ Nothing below asserts how long anything took; only "gone by the deadline".
    static func session(_ agent: ACPAgentProcess) throws -> AgentSession {
        try AgentSession(agent, flushGrace: .milliseconds(200), hardKillAfter: .seconds(1))
    }

    static func isAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    /// Polls rather than sleeping a fixed interval: killing a process is asynchronous
    /// (SIGTERM → the child's handler → the kernel reaping it → `Process`'s termination
    /// handler), so a single read straight after `terminate()` is its own race — the same one
    /// `armKiller`'s doc comment records getting wrong twice. No wall-clock assertion is made;
    /// only "gone by the deadline", which is what the invariant claims.
    static func waitUntilGone(_ pid: Int32, within: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + within
        while ContinuousClock.now < deadline {
            if !isAlive(pid) { return true }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { break }
        }
        return !isAlive(pid)
    }

    @Test("terminating the session ends an agent that ignores its stdin closing")
    func terminateEndsADeafAgent() async throws {
        let session = try Self.session(Self.deafAgent())
        let pid = session.processIdentifier
        #expect(Self.isAlive(pid))
        await session.end()
        #expect(await Self.waitUntilGone(pid))
    }

    /// The second rung. SIGTERM is trapped, so only the SIGKILL follow-up ends this one — and
    /// `Client.terminate()` must actually *reach* the escalation to schedule it (see Step 4:
    /// racing the read loop inside a task group cannot, because the group cannot exit while the
    /// loop is still running).
    @Test("terminating ends an agent that ignores SIGTERM too")
    func terminateEndsAStubbornAgent() async throws {
        let session = try Self.session(Self.stubbornAgent())
        let pid = session.processIdentifier
        #expect(Self.isAlive(pid))
        await session.end()
        #expect(await Self.waitUntilGone(pid, within: .seconds(20)))
    }

    @Test("dropping the session ends its agent")
    func dropEndsTheAgent() async throws {
        // ⚠️ `var` + `= nil` rather than a `do { }` scope: ARC gives no guarantee that a `let`
        // is released at the end of its scope, so a scope-based test is a coin toss dressed as
        // an assertion.
        var session: AgentSession? = try Self.session(Self.deafAgent())
        let pid = session!.processIdentifier
        #expect(Self.isAlive(pid))
        session = nil
        #expect(await Self.waitUntilGone(pid))
    }

    @Test("terminating before the read loop has started is safe")
    func terminateBeforeReadLoopIsSafe() async throws {
        let session = try Self.session(Self.deafAgent())
        let pid = session.processIdentifier
        // ⚠️ `Client.init` defers `startReadLoop()` into a `Task`, so this *aims* at the window
        // where `readLoop` is still nil — but reading `processIdentifier` is an actor hop, so
        // which branch runs is a race and not a guarantee. Both branches must be safe; this
        // test asserts that whichever one ran, the child is gone.
        await session.end()
        #expect(await Self.waitUntilGone(pid))
        // Idempotent at the `AgentSession` level — which is `ended`, not `Client.terminate()`.
        await session.end()
    }

    /// `Client.terminate()`'s **own** idempotency, which `AgentSession.end()`'s `ended` flag
    /// hides. Called twice directly, it must not trap, hang, or resume a continuation twice.
    @Test("Client.terminate is itself safe to call twice")
    func clientTerminateIsIdempotent() async throws {
        let session = try Self.session(Self.deafAgent())
        let pid = session.processIdentifier
        await session.client.terminate()
        await session.client.terminate()
        #expect(await Self.waitUntilGone(pid))
    }
}
