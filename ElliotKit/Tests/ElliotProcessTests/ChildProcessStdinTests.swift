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
}
