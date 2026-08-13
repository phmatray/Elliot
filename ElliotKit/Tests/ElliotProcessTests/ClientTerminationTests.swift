import ACPModel
import Foundation
import Testing

@testable import ACP
@testable import ElliotProcess

/// A `Transport` that owns no child and records what `Client.terminate()` does to it.
///
/// `LoopbackTransport` (`ACPClientTransportTests.swift`) proves the request/response correlation
/// and gives `terminate(hardKillAfter:)` a no-op; this one exists because a no-op cannot be
/// *observed*, and the two branches below are distinguishable only by whether the escalation
/// happened and with which grace.
private final class CountingTransport: Transport, Sendable {
    struct Record: Sendable {
        var closes = 0
        var escalations: [Duration] = []
    }

    let messages: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let record = Locked(Record())

    init() {
        var continuation: AsyncStream<Data>.Continuation!
        messages = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.continuation = continuation!
    }

    func send(_ data: Data) async throws {}

    /// Finishing the stream here is what lets `Client.terminate()`'s `await readLoop.value` return
    /// without a child ever existing — the same chain a real agent's stdout closing produces, which
    /// is why neither test below needs a killer armed the way `AgentSessionLifetimeTests` does.
    func close() async {
        record.withLock { $0.closes += 1 }
        continuation.finish()
    }

    var isConnected: Bool {
        get async { record.withLock { $0.closes == 0 } }
    }

    func terminate(hardKillAfter grace: Duration) {
        record.withLock { $0.escalations.append(grace) }
    }

    var escalations: [Duration] { record.value.escalations }
}

/// The two halves of #381's criterion 4 — *"terminating before the read loop has started is
/// safe"* — pinned one each, deterministically.
///
/// ⛔ **They are here because `AgentSessionLifetimeTests` pins neither, and could not.** That suite
/// reaches these branches only through the scheduler race between `Client.init`'s deferred
/// `startReadLoop()` task and the caller's own hop, so which branch runs is decided for it.
/// Measured on this branch by deleting each half in turn:
///
/// | deleted | what the suite said before these tests existed |
/// |---|---|
/// | the `isTerminated` guard in `startReadLoop()` | **green**, 8 filtered runs of 8 |
/// | the `readLoop == nil` branch's escalation | **red 11 filtered runs in 12** |
///
/// The first of those two was also green across a full run of 2 798 tests: nothing anywhere in the
/// package noticed.
///
/// A guarantee that reports the truth 11 times in 12 is a flake, and one that reports it 0 times
/// in 9 is not pinned at all — on the safety criterion of a task whose subject is agents running
/// at `bypassPermissions` inside real checkouts.
@Suite("Client termination branches")
struct ClientTerminationTests {
    fileprivate static func client(_ transport: CountingTransport) -> Client {
        // A flush grace no test can outlive, so the armed deadline inside `terminate()` can never
        // fire during one of these: every escalation recorded below is one a *branch* performed,
        // never one the timer did. Both branches cancel the deadline, so nothing is left running.
        Client(
            transport: transport, flushGrace: .seconds(600), escalationGrace: Self.escalationGrace)
    }

    /// Distinctive on purpose: it is the evidence that the recorded escalation came from the
    /// branch under test and carried the client's own configured grace, rather than from
    /// `ACPTransport`'s default or `ProcessTermination.hardKillGrace`.
    static let escalationGrace: Duration = .milliseconds(1234)

    /// `Client.init` defers `startReadLoop()` into a `Task`, so a freshly built client has no read
    /// loop *yet*. Both tests need it to have landed before they act, or they are measuring the
    /// same race they exist to take out of the picture.
    ///
    /// Bounded, and returns what it found rather than trapping: an unbounded spin here would be the
    /// hang this file's neighbour arms a killer against.
    static func waitForReadLoop(_ client: Client, within: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + within
        while ContinuousClock.now < deadline {
            if await client.hasReadLoop { return true }
            do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
        }
        return await client.hasReadLoop
    }

    /// The `readLoop == nil` branch, reached with certainty rather than by luck: `terminate()` nils
    /// the field before it returns, so the *second* call cannot take any other path.
    ///
    /// `clientTerminateIsIdempotent` also reaches this branch on its second call and cannot pin it,
    /// because there the child is already dead and the escalation is a no-op nobody can see. Here
    /// the transport records it.
    @Test("terminate with no read loop escalates instead of waiting out a flush nobody is reading")
    func terminateWithoutAReadLoopEscalates() async throws {
        let transport = CountingTransport()
        let client = Self.client(transport)
        #expect(await Self.waitForReadLoop(client))

        // First call: the read loop exists, so this is the flush path. It must escalate nothing —
        // the agent asked to stop is being given its window, and the deadline stands down when the
        // loop ends.
        await client.terminate()
        #expect(await client.hasReadLoop == false)
        #expect(transport.escalations.isEmpty)

        // Second call: no loop, so there is nobody to observe the close and nothing to wait for.
        // Waiting out the flush window here would be waiting for a flush no one is reading, and
        // for a deaf agent it is the difference between the child dying and the child surviving
        // its owner — which is the whole of #381.
        await client.terminate()
        #expect(transport.escalations == [Self.escalationGrace])
    }

    /// The `isTerminated` guard in `startReadLoop()`.
    ///
    /// Calling `startReadLoop()` by hand is exactly the ordering the guard is written for —
    /// `init`'s deferred `Task` landing after a caller has already terminated — and it is the only
    /// way to produce that ordering on demand: from outside, both hops queue on this actor's serial
    /// executor and the scheduler picks. Hence the `internal` on that method, which is a vendored
    /// change carrying this test as its reason.
    @Test("a read loop that starts after terminate does not start at all")
    func startReadLoopAfterTerminateIsANoOp() async throws {
        let transport = CountingTransport()
        let client = Self.client(transport)
        #expect(await Self.waitForReadLoop(client))

        await client.terminate()
        #expect(await client.hasReadLoop == false)

        // Without the guard this stores a `Task` that iterates a transport already closed and, for
        // a real agent, already signalled — a loop nothing will ever cancel, holding the transport
        // and through it the child. That is the leak #381 is named for, restored one line at a
        // time.
        await client.startReadLoop()
        #expect(await client.hasReadLoop == false)
    }
}
