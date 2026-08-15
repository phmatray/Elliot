import ACP
import ACPModel
import Foundation

/// The single owner of one ACP agent: one `ACPTransport`, one `Client`, one child.
///
/// #381 is why this type exists rather than a pair of locals. The retain trace measured while
/// landing #380 was `Client` → `readLoop` (a `Task`) → `transport` (captured strongly at
/// `Client.swift:99`, deliberately, so the loop does not retain `self`) → `ChildProcess` →
/// `Process`, with nothing cancelling the loop and no `deinit` anywhere. A dropped `Client`
/// therefore leaked the task, the transport **and a running agent** — and Elliot's agents run
/// at `bypassPermissions` inside real checkouts, so a leaked one keeps editing files with a
/// live tool budget.
///
/// An `actor` rather than a class: `end()` must be idempotent under concurrent callers, and
/// both the scheduler's cancel path and the run's own completion reach it.
public actor AgentSession {
    public let client: Client

    /// `internal` rather than `private`, the way `ACPTransport.sendRaw` is — production has
    /// `end()` and needs nothing else. The one other reader is `AgentSessionLifetimeTests`, which
    /// arms a deadline able to end this agent from outside the actor.
    ///
    /// It needs one because **every wait in that suite is unbounded and `withTimeout` cannot bound
    /// it**: `end()` reaches `Client.terminate()`, which reaches `await readLoop.value`, and
    /// `Task<Void, Never>.value` observes no cancellation — the three facts `armKiller`'s doc
    /// comment (`Tests/TestSupport/ArmedKiller.swift`) sets out one layer up. The only thing that
    /// ends that wait is the child dying, which is the very behaviour under test, so without a
    /// killer a regression in the escalation makes `swift test` **hang** instead of fail.
    /// Measured with `Client.terminate()`'s two `transport.terminate` calls deleted: killerless,
    /// the filtered suite printed `Build complete! (2.84s)` and then no test line at all for
    /// 150 s; with the killer armed, the same break reported 4 red tests in 24 s.
    ///
    /// `nonisolated` for the same reason `processIdentifier` is: an actor's `let` is implicitly
    /// nonisolated only *within* its own module, so without this a test in `ElliotProcessTests`
    /// gets `actor-isolated property 'transport' cannot be accessed from outside of the actor`.
    /// `ACPTransport` is `Sendable`, so nothing is given up by saying so.
    nonisolated let transport: ACPTransport

    private let killer: Killer
    private var ended = false

    /// The `deinit` backstop, in its own reference type because an `actor`'s `deinit` is
    /// `nonisolated` and may touch nothing isolated. This box holds the one thing a drop must
    /// still be able to do.
    ///
    /// ⛔ Calling `terminate()` from here is possible only because
    /// `Transport.terminate(hardKillAfter:)` is not `async` (#381).
    private final class Killer: Sendable {
        private let transport: ACPTransport
        private let grace: Duration
        init(_ transport: ACPTransport, grace: Duration) {
            self.transport = transport
            self.grace = grace
        }
        deinit { transport.terminate(hardKillAfter: grace) }
    }

    public init(
        _ agent: ACPAgentProcess,
        flushGrace: Duration = Client.defaultFlushGrace,
        hardKillAfter: Duration = ProcessTermination.hardKillGrace
    ) throws {
        let transport = try ACPTransport(agent)
        self.transport = transport
        client = Client(
            transport: transport, flushGrace: flushGrace, escalationGrace: hardKillAfter)
        killer = Killer(transport, grace: hardKillAfter)
    }

    /// `nonisolated`: `ACPTransport` is `Sendable`, nothing here needs the actor, and Task 7's
    /// `AgentRun.processIdentifier` is synchronous and reads this.
    public nonisolated var processIdentifier: Int32 { transport.processIdentifier }

    /// The agent's stderr, for a crash reason: a failed `npx` resolution, a Node stack trace, a
    /// missing `CLAUDE_CODE_EXECUTABLE`.
    public func collectedStderr() -> String { transport.collectedStderr() }

    /// Ends the agent. Idempotent, and safe before the read loop has started.
    public func end() async {
        guard !ended else { return }
        ended = true
        await client.terminate()
    }
}
