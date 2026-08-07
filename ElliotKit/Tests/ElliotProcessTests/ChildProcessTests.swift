import Foundation
import TestSupport
import Testing

@testable import ElliotProcess

/// The mechanism both spawners stand on: spawn a child, drain both its pipes
/// under one lock, publish its exit.
///
/// These are deliberately the same questions `ProcessRunnerTests` and
/// `StreamingProcessDrainTests` ask, asked one layer down. That looks like
/// duplication and is the opposite of it: those two suites now exercise the
/// mechanism through a wrapper each, so a defect in the mechanism reaches them
/// wearing a wrapper's clothes. Here it has none on.
///
/// Every wait is bounded through `withTimeout`. An unbounded `for await` is how
/// one hung child stopped `swift test` from ever exiting, taking the SwiftPM
/// build lock with it — and presenting as a broken toolchain rather than as a
/// stuck test.
@Suite("Child process")
struct ChildProcessTests {

    private static let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

    /// A sink shaped like `ProcessRunner`'s: it only keeps the bytes.
    ///
    /// `finished` counts the close-out rather than recording that it happened,
    /// because "called once" is the claim worth holding — a sink finished twice
    /// is a stream finished twice, which traps.
    private struct BufferingSink: ChildOutputSink {
        var stdout = Data()
        var stderr = Data()
        var finished = 0

        mutating func receiveStdout(_ chunk: Data) { stdout.append(chunk) }
        mutating func receiveStderr(_ chunk: Data) { stderr.append(chunk) }
        mutating func finish() { finished += 1 }
    }

    private static func spawn(_ script: String) throws -> ChildProcess<BufferingSink> {
        try ChildProcess(
            executable: "/bin/sh", arguments: ["-c", script], cwd: nil,
            environment: environment, sink: BufferingSink()
        )
    }

    @Test("A child's output, exit code and close-out are all reported")
    func collectsOutputAndExitCode() async throws {
        let child = try Self.spawn("printf out; printf err >&2; exit 7")
        let termination = try await withTimeout(.seconds(30)) { await child.wait() }

        #expect(termination.code == 7)
        #expect(!termination.wasTerminated)
        #expect(child.withSink { String(decoding: $0.stdout, as: UTF8.self) } == "out")
        #expect(child.withSink { String(decoding: $0.stderr, as: UTF8.self) } == "err")
        // Exactly once: `LineSink.finish()` finishes an `AsyncStream`, and
        // finishing one twice is not merely untidy.
        #expect(child.withSink { $0.finished } == 1)
    }

    /// The tail — what a child writes between the last readability callback and
    /// its exit.
    ///
    /// This is the byte range a naive drain drops, and dropping it is silent:
    /// what goes missing is the *end* of a payload, so it surfaces as malformed
    /// JSON in whatever tried to parse it, never as "the output was truncated".
    /// A full pipe buffer goes out first so the sentinel genuinely arrives after
    /// a callback has already had its go at the descriptor.
    ///
    /// Thirty iterations, the number `StreamingProcessDrainTests` justifies from
    /// measured detection rates: at the worst observed rate of 0.6 per
    /// iteration, thirty miss it with probability 0.4³⁰. One green pass would
    /// say nothing at all.
    @Test("The last thing a child writes before exiting is never lost")
    func capturesTheTail() async throws {
        let sentinel = "LAST-LINE\n"
        let bulk = 65_536
        try await withTimeout(.seconds(120)) {
            for attempt in 0..<30 {
                // `withTimeout` cannot interrupt a `wait()` already in flight —
                // it parks in a `withCheckedContinuation`, which no cancellation
                // reaches — so without this check one wedged iteration would be
                // followed by 29 more and the "bounded" test would sit on the
                // build lock far past its 120 s.
                try Task.checkCancellation()
                let child = try Self.spawn(
                    "yes abcdefghij | head -c \(bulk); printf 'LAST-LINE\\n'"
                )
                let termination = await child.wait()
                let stdout = child.withSink { String(decoding: $0.stdout, as: UTF8.self) }

                #expect(termination.code == 0)
                #expect(
                    stdout.hasSuffix(sentinel),
                    """
                    attempt \(attempt): tail lost — \(stdout.utf8.count) bytes \
                    ending \(String(stdout.suffix(12)).debugDescription)
                    """
                )
                #expect(stdout.utf8.count == bulk + sentinel.utf8.count)
            }
        }
    }

    @Test("A child that writes more than one pipe buffer does not deadlock")
    func largeOutputDoesNotDeadlock() async throws {
        // Both pipes must drain concurrently; 1 MiB is well past the pipe buffer
        // that would otherwise block the child forever.
        let child = try Self.spawn("yes abcdefghij | head -c 1048576; yes k | head -c 200000 >&2")
        let termination = try await withTimeout(.seconds(60)) { await child.wait() }

        #expect(termination.code == 0)
        #expect(child.withSink { $0.stdout.count } == 1_048_576)
        #expect(child.withSink { $0.stderr.count } == 200_000)
    }

    @Test("A child that exits before anyone waits is still reported")
    func exitsImmediately() async throws {
        // The waiter and the termination handler race, and this is the half of
        // that race where the child wins. `wait()` must find the exit already
        // published rather than park behind a handler that has been and gone.
        try await withTimeout(.seconds(60)) {
            for _ in 0..<20 {
                let child = try ChildProcess(
                    executable: "/usr/bin/false", arguments: [], cwd: nil,
                    environment: [:], sink: BufferingSink()
                )
                // Waits on the child's state, never on a fixed interval: a
                // wall-clock sleep fails under load while the code behaved
                // perfectly. Bounded by the enclosing `withTimeout`.
                while child.isRunning { try await Task.sleep(for: .milliseconds(1)) }

                let termination = await child.wait()
                #expect(termination.code == 1)
                #expect(!termination.wasTerminated)
            }
        }
    }

    @Test("Concurrent children each collect their own output, whole")
    func concurrentOutputIsIntact() async throws {
        let payload = String(repeating: "abcdefghij", count: 40)
        let expected = payload + "\n"

        try await withTimeout(.seconds(120)) {
            for _ in 0..<8 {
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<16 {
                        group.addTask {
                            let child = try? ChildProcess(
                                executable: "/bin/echo", arguments: [payload], cwd: nil,
                                environment: Self.environment, sink: BufferingSink()
                            )
                            guard let child else {
                                Issue.record("could not spawn /bin/echo")
                                return
                            }
                            _ = await child.wait()
                            let stdout = child.withSink { String(decoding: $0.stdout, as: UTF8.self) }
                            // Compared by length first, so a failure says how it
                            // broke rather than printing 110 KB twice.
                            #expect(stdout.count == expected.count, "got \(stdout.count) bytes")
                            #expect(stdout == expected)
                        }
                    }
                }
            }
        }
    }

    @Test("A child asked to stop reports that it was terminated")
    func terminationIsRecorded() async throws {
        // `wasTerminated` is the one field of `ChildTermination` that no exit
        // status can carry, so it is the one the wrappers cannot check for
        // themselves: `StreamingProcess.Exit` copies it straight out.
        let child = try Self.spawn("sleep 30")
        child.terminate(hardKillAfter: .milliseconds(300))
        let termination = try await withTimeout(.seconds(30)) { await child.wait() }

        #expect(termination.wasTerminated)
        // Names the signal that stopped it, so a child that had quietly died of
        // something else could not pass.
        #expect(termination.code == SIGTERM, "expected SIGTERM, got \(termination.code)")
    }

    @Test("Something that is not an executable is refused before it is launched")
    func refusesNonExecutable() {
        #expect(throws: ProcessError.self) {
            _ = try ChildProcess(
                executable: "/etc/hosts", arguments: [], cwd: nil,
                environment: [:], sink: BufferingSink()
            )
        }
    }
}
