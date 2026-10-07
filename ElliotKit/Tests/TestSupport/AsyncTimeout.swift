import Foundation

/// Thrown when a bounded wait outlives its deadline.
public struct TimedOut: Error, CustomStringConvertible {
    public let seconds: Double
    public init(seconds: Double) { self.seconds = seconds }
    public var description: String { "timed out after \(seconds)s" }
}

/// Races `operation` against `duration` — but only bounds waits that observe cancellation.
/// `withThrowingTaskGroup` cannot exit while a child task is still running: `group.cancelAll()`
/// asks the still-running `operation()` task to stop, it does not evict it, and the group awaits
/// it regardless on the way out. So this genuinely bounds an `operation` built from
/// cancellation-aware pieces (`Task.sleep`, cooperative loops), and it does **not** bound
/// `ChildProcess.wait()` or any `Client` request sent with `timeout: nil` — both suspend on a bare
/// `withCheckedContinuation`/`withCheckedThrowingContinuation` that no cancellation reaches, so
/// wrapping either in `withTimeout` throws away the seconds you asked for and hangs anyway.
///
/// Measured the hard way (Task 7): a wedged `ACPSessionTests/fullTurn` ran 10m51s and held the
/// SwiftPM build lock while another build sat behind it for 600s — this function's `group.next()`
/// never returned because the operation side of the race never finished, cancelled or not.
///
/// For those waits, the guard that actually works is a deadline that ends the *source* rather than
/// the wait: kill the child (or `Client`'s transport) from a concurrently-running task, which makes
/// the awaited call fail on its own rather than being raced out of existence. See `armKiller` in
/// `ArmedKiller.swift`, beside this file, for the shape, and its doc comment for why the flag it
/// sets is checked rather than `transport.isConnected` read immediately after `terminate()` is
/// called.
public func withTimeout<T: Sendable>(
    _ duration: Duration = .seconds(10),
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw TimedOut(seconds: Double(duration.components.attoseconds) / 1e18
                + Double(duration.components.seconds))
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
