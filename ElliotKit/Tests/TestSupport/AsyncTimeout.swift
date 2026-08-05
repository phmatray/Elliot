import Foundation

/// Thrown when a bounded wait outlives its deadline.
public struct TimedOut: Error, CustomStringConvertible {
    public let seconds: Double
    public init(seconds: Double) { self.seconds = seconds }
    public var description: String { "timed out after \(seconds)s" }
}

/// Races `operation` against `duration`. The test harness uses this so a wedged
/// child process fails its test in seconds instead of hanging `swift test` —
/// and with it the SwiftPM build lock — indefinitely.
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
