import Synchronization

/// A reference-typed box around `Mutex`.
///
/// `Mutex` is non-copyable, so a local one cannot be captured by the several
/// escaping closures a `Process` needs — its readability handlers and its
/// termination handler all mutate the same buffers. Holding it behind a class
/// gives those closures a shared reference to capture.
final class Locked<Value>: Sendable where Value: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) {
        mutex = Mutex(value)
    }

    func withLock<Result: Sendable>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try mutex.withLock { value in try body(&value) }
    }

    var value: Value {
        mutex.withLock { $0 }
    }
}
