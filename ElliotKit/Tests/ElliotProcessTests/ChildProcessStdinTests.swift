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

    /// A weaker, behavioral sibling of `defaultStdinIsWiredToDevNull` below: it only proves a
    /// default-stdin child terminates rather than blocking, never *why*. `cat` exits on EOF whether
    /// that EOF comes from `/dev/null` or from an inherited descriptor that already happened to be
    /// closed — measured directly, in `swiftpm-testing-helper`'s own process, both look the same. The
    /// name used to claim the stronger fact; it no longer does.
    @Test("a child spawned with the default stdin terminates rather than blocking")
    func defaultStdinTerminatesRatherThanBlocking() async throws {
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

    /// The white-box replacement for the behavioral pin above. Asks the child what its own fd 0
    /// actually is, rather than inferring it from whether the child happens to exit — `stat -f
    /// "%Hr,%Lr"` prints a special file's raw device number, and comparing `/dev/fd/0` against
    /// `/dev/null` **in the same command** means the assertion carries no machine-specific constant:
    /// it holds regardless of what `/dev/null`'s actual device number is on a given host.
    ///
    /// Measured on this machine: `.null` gives `"3,2\n3,2"` (equal); a `.pipe` child asked the same
    /// question gives `"0,0\n3,2"` (a pipe's rdev is always zero — they differ).
    ///
    /// ⚠️ Measured to fail intermittently, rarely, for a reason not yet found — read this before
    /// treating a lone red run here as a confirmed regression, and before dismissing one as noise.
    /// The failure looks exactly like `fd 0 rdev 0,0 != /dev/null rdev 3,2` (grep for that string).
    /// Observed once in 75 runs by one investigator and zero times in 80 by a second (40 at default
    /// parallelism, 40 with `--no-parallel`) — combined, 1 failure in 155 runs, roughly 0.65%. The
    /// clean batch does **not** refute the failed one: at a ~1.3% single-observer rate, seeing zero
    /// failures across 80 runs happens by chance about 35% of the time, so treat the two as
    /// consolidating toward ~0.65%, not as contradicting each other. When it failed,
    /// `ChildProcess.swift` was confirmed byte-identical to the committed source at the time — this
    /// was not a break-test artefact and not an uncommitted edit caught mid-flight.
    ///
    /// The failure's shape says something specific: `rdev 0,0` is a pipe's device number, so the
    /// child's fd 0 was briefly an **open pipe**, not `/dev/null` and not a closed descriptor. This
    /// package's only spawner (`ChildProcess`) creates a pipe for stdout and a pipe for stderr on
    /// every single spawn, and this board spawns children concurrently — so the standing,
    /// **unverified** hypothesis is a narrow race in how `FileHandle.nullDevice`'s descriptor is
    /// captured for `posix_spawn`'s file actions while a concurrent spawn is creating its own pipes.
    /// If that hypothesis is right, this is a defect in the only spawner in the package, not an
    /// artefact of this test — nobody has isolated a mechanism, so it stays labelled a hypothesis.
    ///
    /// ⛔ No retry, tolerance, or second acceptable rdev was added to quiet this, and none should be.
    /// Two rounds of review went into making this test capable of failing at all — its predecessor
    /// asserted only that `cat` exited, which is true on EOF from anywhere and caught nothing. A
    /// retry would make this one just as blind again, on purpose, to suppress the one signal that
    /// would ever show a real spawn-time race.
    @Test("a default-stdin child's fd 0 is wired to /dev/null, not the app's own stdin")
    func defaultStdinIsWiredToDevNull() async throws {
        var continuation: AsyncStream<Data>.Continuation!
        let chunks = AsyncStream<Data> { continuation = $0 }

        let child = try ChildProcess(
            executable: "/bin/sh",
            arguments: ["-c", "stat -f \"%Hr,%Lr\" /dev/fd/0 /dev/null"],
            cwd: nil,
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            sink: Collector(continuation: continuation!)
        )

        // Accumulate every chunk and wait for the stream to finish rather than asserting on the
        // first: two short lines can arrive in one callback or split across two.
        let output = try await withTimeout(.seconds(5)) { () -> Data in
            var collected = Data()
            for await chunk in chunks {
                collected.append(chunk)
            }
            return collected
        }

        let termination = try await withTimeout(.seconds(5)) { await child.wait() }
        #expect(termination.code == 0)

        let lines = String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n")
            .map(String.init)
        #expect(lines.count == 2, "expected two stat lines, got \(lines)")
        #expect(lines.first == lines.last, "fd 0 rdev \(lines.first ?? "?") != /dev/null rdev \(lines.last ?? "?")")
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
