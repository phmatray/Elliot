import Foundation
import Synchronization

/// Whether an armed killer's body actually ran. Set synchronously, inside the task the caller
/// already awaits, so reading it races nothing.
///
/// A two-line box over `Mutex` rather than `ElliotProcess.Locked`, because `TestSupport` depends
/// on nothing (`Package.swift`) and is linked into every suite: reaching for `Locked` would make
/// this target import `ElliotProcess` — and `Locked` is `internal` there — so a helper about
/// bounded waits would drag the package's spawner into `ElliotStoreTests`.
public final class KillerFlag: Sendable {
    private let flag = Mutex(false)

    func fire() { flag.withLock { $0 = true } }

    public var value: Bool { flag.withLock { $0 } }
}

/// Arms a deadline that runs `kill` unless cancelled first — armed right after the thing it
/// guards exists, so it is the one mechanism able to bound *every* wait that follows: an ACP
/// `initialize`, `newSession` and `setConfigOption` reach the identical unguarded
/// `sendRequest(..., timeout: nil)` that `sendPrompt` does, so they need this exactly as much.
/// See `AsyncTimeout.swift`'s doc comment for why `withTimeout` cannot bound any of them on its
/// own — this exists because that guarantee does not hold.
///
/// ⚠️ `kill` is a closure rather than a transport because this target may not import
/// `ElliotProcess`; what the helper is *about* is unchanged — end the **source** of the wait, and
/// prove whether the deadline fired. `ACPSessionTests` and `ACPRunnerTests` both pass
/// `{ transport.terminate() }`.
///
/// None of those waits can be bounded the ways that look obvious:
/// - Every `Client` request reaches `sendRequest(..., timeout: nil)`, which suspends on a bare
///   `withCheckedThrowingContinuation` — nothing about it observes cancellation. Wrapping one in
///   `withTimeout` does not help: `withThrowingTaskGroup` is a structured-concurrency scope, and a
///   scope cannot exit while a child task is still running, cancelled or not —
///   `group.cancelAll()` asks, it does not evict.
/// - A notification collector written as a plain `Task<[T], Never>` is non-throwing, so `.value`
///   is `get async`, not `get async throws`, and cannot even signal cancellation. `withTimeout`
///   around `await updates.value` is exactly as broken as around `sendPrompt`, for the identical
///   reason, and was the second Critical `ACPSessionTests` shipped with once.
///
/// The only thing that actually ends any of them is ending the *agent*: `terminate()`
/// (`ACPTransport.swift`) kills the child, which closes its stdout, which finishes
/// `transport.messages`, which ends `Client`'s read loop, which fails every still-pending request
/// through `handleTermination()` **and** finishes the notification stream — so a stuck
/// `sendPrompt` throws, and a short-of-N collector returns with fewer than it wanted, instead of
/// either one hanging. Break-tested: pointed a copy of `fullTurn` at a 2-frame fixture (short of
/// the 8 the collector wants) with a 3 s deadline — it **failed** at 3.06 s on
/// `collected.count == 8`, not a hang, which is what this whole mechanism exists to guarantee for
/// the notification-collection half.
///
/// ⛔ The sleep below is deliberately **not** `try? await Task.sleep(...)` followed by an
/// unconditional `kill()`. That was `ACPSessionTests`'s first Critical: `try?` swallows
/// `Task.sleep`'s `CancellationError` and execution falls straight through to the kill regardless
/// of *why* the sleep ended — so `killer.cancel()` did not disarm the kill, it **triggered** it,
/// within milliseconds of every successful call (reviewer's own standalone probe: cancel at
/// 0.05 s, `terminate()` at 0.06 s). Both tests still passed, correctly by accident — the double
/// writes every `session/update` line before its `session/prompt` reply, so a collector reading an
/// already-finished stream still drains a full buffer.
///
/// The returned flag is the proof that this version does not repeat that, and it is read-only
/// outside a test — production has no need of it. ⚠️ It does **not** read
/// `transport.isConnected` for the proof, and getting to that took two wrong attempts, both
/// measured directly against the reintroduced buggy body above:
/// 1. `#expect(await transport.isConnected)` placed where `defer { killer.cancel() }` was the only
///    cancellation — passed even with the bug present, because the check ran before the function
///    returned, i.e. before `defer` had cancelled anything at all. Not a race, simply the wrong
///    order.
/// 2. `killer.cancel(); await killer.value; #expect(await transport.isConnected)` — still passed
///    with the bug present. Killing a process is inherently asynchronous (SIGTERM → the child's own
///    handler → the kernel reaping it → `Process`'s termination handler updating `isRunning`), so
///    `isConnected` read immediately after `terminate()` was *called* is its own race, one layer
///    below the Swift-cancellation race this helper exists to close — the child had not finished
///    dying yet by the time the check ran.
///
/// The flag closes both gaps: it is set synchronously, in the same task whose completion the caller
/// already awaits, so there is nothing left to race. Reintroducing the buggy body a third time,
/// with this check, failed both tests immediately and correctly.
public func armKiller(
    deadline: Duration = .seconds(20),
    kill: @escaping @Sendable () -> Void
) -> (killer: Task<Void, Never>, fired: KillerFlag) {
    let fired = KillerFlag()
    let killer = Task {
        do {
            try await Task.sleep(for: deadline)
        } catch {
            return  // cancelled — a real reply or a full collection arrived first
        }
        fired.fire()
        kill()
    }
    return (killer, fired)
}
