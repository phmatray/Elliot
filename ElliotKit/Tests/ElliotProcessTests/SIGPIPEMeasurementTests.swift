import Foundation
import Testing
import TestSupport

@testable import ElliotProcess

/// Measures, rather than assumes, what happens when `writeStdin` is called after the child has
/// already exited.
///
/// The concern: the read end of a pipe closing while something still holds the write end open is
/// the textbook SIGPIPE trigger, and SIGPIPE's default disposition **terminates the process** — not
/// just the write. `grep -rn "SIGPIPE\|NOSIGPIPE\|signal(" Sources` returned nothing before this
/// test existed, so this package set no disposition of its own, and whether Swift, Foundation or
/// libdispatch already installed `SIG_IGN` on Darwin was unmeasured. `ACPTransport.send` calls
/// `writeStdin` from an `async` context that has no way to know the agent exited moments earlier —
/// a JSON-RPC request racing the agent's own shutdown is an ordinary case, not an edge one.
///
/// This is written as its own suite, separate from `ChildProcessStdinTests`, so a first run can be
/// isolated with `swift test --filter SIGPIPEMeasurementTests` — when this test was first written,
/// against `ChildProcess` before this fix existed, that isolation mattered: the whole test *process*
/// died rather than this one test going red, and that was far easier to read in isolation than
/// mixed into a 300-suite run.
///
/// ## Measured 2026-08-12
///
/// **Before the fix**, run 3/3 times in isolation: the test process died outright —
/// `swiftpm-testing-helper` exited with "unexpected signal code 13" (`SIGPIPE`), no failing
/// `#expect`, no thrown error the test could ever have caught. That is what sent
/// `ChildProcess.init`'s `.pipe` arm the `fcntl(fd, F_SETNOSIGPIPE, 1)` guard it now carries — see
/// the comment there for the reasoning; this file only re-verifies its effect.
///
/// **After the fix**, run 5/5 times: `writeStdin` throws instead of killing the process, every time
/// with the identical shape —
/// `NSCocoaErrorDomain Code=512 "The file couldn't be saved."` wrapping
/// `NSPOSIXErrorDomain Code=32 "Broken pipe"` under `NSUnderlyingErrorKey`. Code 32 is `EPIPE`. This
/// is `FileHandle.write(contentsOf:)`'s ordinary translation of a `write(2)` call that returned -1,
/// which is exactly what `F_SETNOSIGPIPE` is documented to turn a would-be `SIGPIPE` into — measured
/// below rather than assumed, since a `CheckedContinuation` resume of the wrong shape would look
/// identical from the call site.
@Suite("SIGPIPE on write-after-exit")
struct SIGPIPEMeasurementTests {
    /// Collects stdout under the drain lock, exactly as every other sink does.
    private struct Collector: ChildOutputSink {
        let continuation: AsyncStream<Data>.Continuation
        mutating func receiveStdout(_ chunk: Data) { continuation.yield(chunk) }
        mutating func receiveStderr(_ chunk: Data) {}
        mutating func finish() { continuation.finish() }
    }

    @Test("writing to a piped child's stdin after it has exited throws rather than killing the process")
    func writeAfterExitThrows() async throws {
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

        child.terminate()
        let termination = try await withTimeout(.seconds(5)) { await child.wait() }
        #expect(termination.wasTerminated)

        // If this line's process dies rather than this expectation failing, the fix in
        // `ChildProcess.init`'s `.pipe` arm has regressed: SIGPIPE is live and process-fatal
        // again, and this is the guard that is supposed to prevent it.
        var caught: (any Error)?
        do {
            try child.writeStdin(Data("after exit\n".utf8))
        } catch {
            caught = error
        }
        let error = try #require(caught, "expected writeStdin to throw after the child exited")
        print("SIGPIPE measurement: writeStdin after exit threw \(error)")

        // Not just "some throw" — the measured shape specifically, so a change that makes
        // `writeStdin` throw for an unrelated reason (say, a state-tracking bug that always
        // reports `.stdinClosed`) does not read as this guard still working. Checked via the
        // underlying POSIX error rather than the outer `NSCocoaErrorDomain` code, which
        // `FileHandle.write(contentsOf:)` is free to change between OS releases; `EPIPE` is the
        // fact `F_SETNOSIGPIPE` is documented to produce and the fact this test exists to pin.
        let nsError = error as NSError
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        #expect(underlying?.domain == NSPOSIXErrorDomain, "unexpected error shape: \(error)")
        #expect(underlying?.code == Int(EPIPE), "expected EPIPE (\(EPIPE)), got \(String(describing: underlying?.code))")
    }
}
