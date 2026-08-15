import ACP
import ACPModel
import Foundation
import Testing

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

    /// Arms a deadline that ends `transport` unless cancelled first — `TestSupport`'s `armKiller`
    /// (`Tests/TestSupport/ArmedKiller.swift`, where Task 7 lifted `ACPSessionTests`' copy so two
    /// suites could share one), here for the same reason it exists there.
    ///
    /// ⚠️ **This is a third copy of a mechanism that is now shared, and it is left as one
    /// deliberately rather than overlooked.** Folding it in needs `import TestSupport` in this
    /// file, which the paragraph below declines on the grounds that the import would *suggest*
    /// `withTimeout` guards these waits. That reason is weaker now than when it was written —
    /// `TestSupport` holds `armKiller` itself, so the import would carry the guard that does work
    /// — but it is a decision this file's own task took, not one to reverse in passing. The
    /// behavioural difference is real and would become a parameter: the kill here is impolite
    /// (`hardKillAfter: .milliseconds(100)`) because the tree is already broken by the time it
    /// runs.
    ///
    /// ⛔ **Without this, a regression in the escalation makes `swift test` hang rather than
    /// fail.** Every wait below is `await session.end()` or `await session.client.terminate()`,
    /// both of which reach `Client.terminate()`'s `await readLoop.value`; `Task<Void, Never>.value`
    /// observes no cancellation, so `withTimeout` cannot bound any of them — `AsyncTimeout.swift`'s
    /// doc comment sets out why, and `armKiller`'s repeats it. The only thing that ends that wait
    /// is the child's stdout closing, which is the child dying, which is the very behaviour under
    /// test: the liveness of this suite would otherwise rest entirely on the code it is judging.
    ///
    /// Measured both ways, on this branch, with `Client.terminate()`'s two `transport.terminate`
    /// calls deleted — the regression this guards against:
    ///
    /// | deadline | what `swift test --filter AgentSessionLifetimeTests` did |
    /// |---|---|
    /// | pushed past the watchdog | `Build complete! (2.84s)`, then **zero test lines** for 150 s |
    /// | as shipped | 4 red in **24 s**, `terminateEndsADeafAgent` naming `killerFired → true` |
    ///
    /// That is also why `import TestSupport` is **not** in this file: an import suggesting
    /// `withTimeout` guards these waits would be a claim the module cannot keep.
    ///
    /// ⛔ `do`/`catch`, never `try? await Task.sleep(...)`: `try?` swallows `CancellationError` and
    /// falls straight through to the kill, which is how #380's killer fired instead of standing
    /// down. `fired` is the proof that this one does not — read only after `await killer.value`,
    /// since `.cancel()` alone proves nothing about a task not yet scheduled to observe it.
    ///
    /// Twenty seconds is comfortably above the healthy path, which is `flushGrace` (200 ms) plus
    /// at most `hardKillAfter` (1 s). The kill itself is impolite on purpose: by the time it runs,
    /// the tree is already broken and the only job left is to leave a red line rather than a
    /// wedged build lock.
    static func armKiller(_ transport: ACPTransport, deadline: Duration = .seconds(20)) -> (
        killer: Task<Void, Never>, fired: Locked<Bool>
    ) {
        let fired = Locked(false)
        let killer = Task {
            do {
                try await Task.sleep(for: deadline)
            } catch {
                return  // cancelled — the agent died on its own, which is the whole claim
            }
            fired.withLock { $0 = true }
            transport.terminate(hardKillAfter: .milliseconds(100))
        }
        return (killer, fired)
    }

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
        let (killer, killerFired) = Self.armKiller(session.transport)
        defer { killer.cancel() }
        let pid = session.processIdentifier
        #expect(Self.isAlive(pid))
        await session.end()
        killer.cancel()
        await killer.value
        #expect(!killerFired.value)
        #expect(await Self.waitUntilGone(pid))
    }

    /// The second rung. SIGTERM is trapped, so only the SIGKILL follow-up ends this one — and
    /// `Client.terminate()` must actually *reach* the escalation to schedule it (see Step 4:
    /// racing the read loop inside a task group cannot, because the group cannot exit while the
    /// loop is still running).
    @Test("terminating ends an agent that ignores SIGTERM too")
    func terminateEndsAStubbornAgent() async throws {
        let session = try Self.session(Self.stubbornAgent())
        let (killer, killerFired) = Self.armKiller(session.transport)
        defer { killer.cancel() }
        let pid = session.processIdentifier
        #expect(Self.isAlive(pid))
        await session.end()
        killer.cancel()
        await killer.value
        #expect(!killerFired.value)
        #expect(await Self.waitUntilGone(pid, within: .seconds(20)))
    }

    @Test("dropping the session ends its agent")
    func dropEndsTheAgent() async throws {
        // ⚠️ `var` + `= nil` rather than a `do { }` scope: ARC gives no guarantee that a `let`
        // is released at the end of its scope, so a scope-based test is a coin toss dressed as
        // an assertion.
        //
        // The only test here with no killer armed, and deliberately: it holds no unbounded wait.
        // Nothing below awaits the read loop — `waitUntilGone` carries its own deadline and
        // returns a `Bool` — so a regression fails this test rather than hanging it. Arming one
        // anyway would mean holding `transport` in a local across the drop, which is a second
        // strong reference into the object graph whose unwinding is the whole subject.
        var session: AgentSession? = try Self.session(Self.deafAgent())
        let pid = session!.processIdentifier
        #expect(Self.isAlive(pid))
        session = nil
        #expect(await Self.waitUntilGone(pid))
    }

    /// ⚠️ **This test does not pin the branch its name describes, and nothing it could do would.**
    /// `Client.init` defers `startReadLoop()` into a `Task`, so this *aims* at the window where
    /// `readLoop` is still nil — but both that task's hop and `end()`'s hop go to the same actor's
    /// serial executor, and which arrives first is a race decided by the scheduler. Measured on
    /// this branch by deleting the escalation the nil branch performs: 11 filtered runs out of 12
    /// went red, 1 went green. A pin that reports the truth 11 times in 12 is not a pin.
    ///
    /// ⛔ An earlier version of this comment blamed the race on *"reading `processIdentifier` is
    /// an actor hop"*. It is not: `AgentSession.processIdentifier` is `nonisolated` (deliberately —
    /// Task 7's `AgentRun.processIdentifier` is synchronous and reads it), so it suspends nothing
    /// and the window it described does not exist. The only suspension before `end()` is `end()`.
    ///
    /// What this test is worth is the end-to-end claim: **whichever branch ran, the child is
    /// gone.** The two branches themselves are pinned deterministically, one each, by
    /// `ClientTerminationTests`.
    @Test("terminating before the read loop has started is safe")
    func terminateBeforeReadLoopIsSafe() async throws {
        let session = try Self.session(Self.deafAgent())
        let (killer, killerFired) = Self.armKiller(session.transport)
        defer { killer.cancel() }
        let pid = session.processIdentifier
        await session.end()
        killer.cancel()
        await killer.value
        #expect(!killerFired.value)
        #expect(await Self.waitUntilGone(pid))
        // Idempotent at the `AgentSession` level — which is `ended`, not `Client.terminate()`.
        await session.end()
    }

    /// `Client.terminate()`'s **own** idempotency, which `AgentSession.end()`'s `ended` flag
    /// hides. Called twice directly, it must not trap, hang, or resume a continuation twice.
    ///
    /// ⚠️ The second call is guaranteed to take the `readLoop == nil` branch — `terminate()` nils
    /// the field before returning — but it reaches it against a child that is **already dead**, so
    /// the escalation it performs is a no-op and deleting that escalation leaves this test green.
    /// It says the second call is *harmless*, never that the nil branch *works*; the branch is
    /// pinned by `ClientTerminationTests.terminateWithoutAReadLoopEscalates`, against a transport
    /// that records the call.
    @Test("Client.terminate is itself safe to call twice")
    func clientTerminateIsIdempotent() async throws {
        let session = try Self.session(Self.deafAgent())
        let (killer, killerFired) = Self.armKiller(session.transport)
        defer { killer.cancel() }
        let pid = session.processIdentifier
        await session.client.terminate()
        await session.client.terminate()
        killer.cancel()
        await killer.value
        #expect(!killerFired.value)
        #expect(await Self.waitUntilGone(pid))
    }
}
