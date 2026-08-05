import ElliotIPC
import Foundation
import Testing

@testable import ElliotMCPKit

private func currentThreadID() -> UInt32 { pthread_mach_thread_np(pthread_self()) }

/// A count that can be read from another thread.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Where the helper is allowed to block.
///
/// `IPCClient.send` is a blocking `read()` with a socket timeout, and
/// `board_await_run` holds it for up to five minutes on purpose. Awaited
/// straight from a tool function it parks a thread the Swift runtime hands out
/// sparingly — one per core — for that whole window, and the MCP SDK dispatches
/// every request in its own task, so concurrent waits compound.
///
/// What is asserted here is the mechanism, not the symptom: a starved
/// cooperative pool cannot be observed from a test that itself runs on it, and a
/// test that cannot fail is worse than none. So the property pinned is the one
/// the fix actually establishes — the blocking happens somewhere else, and
/// several of them happen at once.
@Suite("Blocking off the cooperative pool")
struct BlockingIOTests {

    @Test("Blocking work does not run on the thread that awaited it")
    func blockingLeavesTheCallersThread() async {
        // `pthread_mach_thread_np` rather than `Thread.current`, which Swift
        // withholds from async code for the very reason this test exists.
        let before = currentThreadID()
        let inside = await BlockingIO.run { currentThreadID() }
        let after = currentThreadID()

        // Compared against both sides: an async function may resume on another
        // thread by itself, and one coincidence must not read as a pass.
        #expect(inside != before)
        #expect(inside != after)
    }

    @Test("The value comes back")
    func valueIsReturned() async {
        #expect(await BlockingIO.run { 6 * 7 } == 42)
    }

    @Test("Waits overlap rather than queueing behind each other")
    func waitsAreConcurrent() async {
        // A serial queue would take the wedge off the cooperative pool and put
        // it somewhere else: one long await would then hold every other request
        // on this helper.
        let waiters = 8
        let entered = Counter()
        let release = DispatchSemaphore(value: 0)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<waiters {
                group.addTask {
                    await BlockingIO.run {
                        entered.increment()
                        _ = release.wait(timeout: .now() + 5)
                    }
                }
            }

            let deadline = Date().addingTimeInterval(5)
            while entered.count < waiters, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            #expect(entered.count == waiters)

            for _ in 0..<waiters { release.signal() }
        }
    }
}
