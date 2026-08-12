import Foundation
import Testing
import TestSupport

@testable import ElliotProcess

/// `cat` is the whole harness: it echoes stdin to stdout and exits when stdin closes, so one
/// spawn exercises writing, reading back, and the close that ends the child.
@Suite("Child process stdin")
struct ChildProcessStdinTests {
    /// Collects stdout under the drain lock, exactly as every other sink does.
    private struct Collector: ChildOutputSink {
        let continuation: AsyncStream<Data>.Continuation
        mutating func receiveStdout(_ chunk: Data) { continuation.yield(chunk) }
        mutating func receiveStderr(_ chunk: Data) {}
        mutating func finish() { continuation.finish() }
    }

    @Test("a piped child receives what is written to its stdin")
    func writesReachTheChild() async throws {
        var continuation: AsyncStream<Data>.Continuation!
        let chunks = AsyncStream<Data> { continuation = $0 }

        let child = try ChildProcess(
            executable: "/bin/cat",
            arguments: [],
            cwd: nil,
            environment: [:],
            stdin: .pipe,
            sink: Collector(continuation: continuation!)
        )

        try child.writeStdin(Data("hello\n".utf8))

        let first = try await withTimeout(.seconds(5)) {
            var iterator = chunks.makeAsyncIterator()
            return await iterator.next()
        }
        #expect(String(decoding: first ?? Data(), as: UTF8.self) == "hello\n")

        child.closeStdin()
        let termination = try await withTimeout(.seconds(5)) { await child.wait() }
        #expect(termination.code == 0)
    }

    @Test("a child spawned with the default stdin refuses a write")
    func defaultStdinRefusesWrites() throws {
        var continuation: AsyncStream<Data>.Continuation!
        _ = AsyncStream<Data> { continuation = $0 }

        let child = try ChildProcess(
            executable: "/bin/cat",
            arguments: [],
            cwd: nil,
            environment: [:],
            sink: Collector(continuation: continuation!)
        )
        defer { child.terminate() }

        #expect(throws: ProcessError.self) {
            try child.writeStdin(Data("hello\n".utf8))
        }
    }

    /// Pins the tri-state distinction directly: a write after the pipe has been closed must not be
    /// mistaken for a write that was never piped at all — the two used to share one `nil`.
    @Test("writing after closeStdin throws stdinClosed, not stdinNotPiped")
    func writeAfterCloseThrowsStdinClosed() async throws {
        var continuation: AsyncStream<Data>.Continuation!
        _ = AsyncStream<Data> { continuation = $0 }

        let child = try ChildProcess(
            executable: "/bin/cat",
            arguments: [],
            cwd: nil,
            environment: [:],
            stdin: .pipe,
            sink: Collector(continuation: continuation!)
        )
        child.closeStdin()

        do {
            try child.writeStdin(Data("too late\n".utf8))
            Issue.record("expected writeStdin to throw once stdin is closed")
        } catch let error as ProcessError {
            guard case .stdinClosed = error else {
                Issue.record("expected .stdinClosed, got \(error)")
                return
            }
        }

        let termination = try await withTimeout(.seconds(5)) { await child.wait() }
        #expect(termination.code == 0)
    }

    @Test("closeStdin can be called twice without throwing or crashing")
    func closeStdinIsIdempotent() async throws {
        var continuation: AsyncStream<Data>.Continuation!
        _ = AsyncStream<Data> { continuation = $0 }

        let child = try ChildProcess(
            executable: "/bin/cat",
            arguments: [],
            cwd: nil,
            environment: [:],
            stdin: .pipe,
            sink: Collector(continuation: continuation!)
        )

        child.closeStdin()
        child.closeStdin()

        let termination = try await withTimeout(.seconds(5)) { await child.wait() }
        #expect(termination.code == 0)
    }

    /// Pins the one line the whole file is named after: `.null` means the child gets EOF from
    /// `/dev/null`, not that it inherits the app's terminal. Nobody here closes anything — `cat`
    /// exits 0 on its own only if its stdin was already at end-of-file the moment it started.
    @Test("a child spawned with the default stdin gets immediate EOF, never the app's own stdin")
    func defaultStdinIsClosedNotInherited() async throws {
        var continuation: AsyncStream<Data>.Continuation!
        _ = AsyncStream<Data> { continuation = $0 }

        let child = try ChildProcess(
            executable: "/bin/cat",
            arguments: [],
            cwd: nil,
            environment: [:],
            sink: Collector(continuation: continuation!)
        )

        let termination = try await withTimeout(.seconds(5)) { await child.wait() }
        #expect(termination.code == 0)
    }

    /// The stdin twin of `ChildProcessTests.largeOutputDoesNotDeadlock`: 1 MiB is comfortably past
    /// the 64 KB pipe buffer in both directions, so this only completes if the write and the
    /// concurrent stdout drain are genuinely independent of one another.
    @Test("a write larger than the pipe buffer does not deadlock while the sink drains")
    func largeWriteDoesNotDeadlock() async throws {
        var continuation: AsyncStream<Data>.Continuation!
        let chunks = AsyncStream<Data> { continuation = $0 }

        let child = try ChildProcess(
            executable: "/bin/cat",
            arguments: [],
            cwd: nil,
            environment: [:],
            stdin: .pipe,
            sink: Collector(continuation: continuation!)
        )

        let payload = Data(repeating: 0x61, count: 1_048_576)

        let received = try await withTimeout(.seconds(30)) { () -> Data in
            try child.writeStdin(payload)
            child.closeStdin()

            var collected = Data()
            for await chunk in chunks {
                collected.append(chunk)
            }
            return collected
        }

        #expect(received.count == payload.count, "got \(received.count) bytes")
        #expect(received == payload)

        let termination = try await withTimeout(.seconds(5)) { await child.wait() }
        #expect(termination.code == 0)
    }
}
