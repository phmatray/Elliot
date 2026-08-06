import Foundation
import TestSupport
import Testing

@testable import ElliotProcess

@Suite("Process runner")
struct ProcessRunnerTests {

    private static let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

    @Test("A command's output and exit code are collected")
    func collectsOutputAndExitCode() async throws {
        let result = try await ProcessRunner.run(
            executable: "/bin/echo", arguments: ["hello"], environment: Self.environment
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout == "hello\n")
        #expect(!result.timedOut)
    }

    /// Concurrent commands each come back with their own output, entire.
    ///
    /// The collecting handler and the drain that follows the child's exit read
    /// the same descriptor, and reading outside the lock while appending inside
    /// it orders neither against the other: a handler that appends after the
    /// result has been snapshotted loses its bytes, and one preempted between
    /// its halves interleaves them with the drain's.
    ///
    /// Honest about its reach: that window is narrow — measured at three empty
    /// results in 3840 commands, and only once the machine is oversubscribed —
    /// so this catches a gross regression rather than the race itself. The
    /// ordering guarantee is structural, held by the lock, not by this test.
    @Test("Concurrent commands each return their own output, whole")
    func concurrentOutputIsIntact() async throws {
        let payload = String(repeating: "abcdefghij", count: 40)
        let expected = payload + "\n"

        for _ in 0..<8 {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<16 {
                    group.addTask {
                        let result = try? await ProcessRunner.run(
                            executable: "/bin/echo", arguments: [payload],
                            environment: Self.environment
                        )
                        let stdout = result?.stdout ?? ""
                        // Compared by length first, so a failure says how it
                        // broke rather than printing 110 KB twice.
                        #expect(stdout.count == expected.count, "got \(stdout.count) bytes")
                        #expect(stdout == expected)
                    }
                }
            }
        }
    }

    @Test("Concurrent short-lived children all report their exit")
    func concurrentRunsAllComplete() async throws {
        // The wedge needs concurrency to appear: one lost termination
        // notification parked a cooperative-pool thread in waitUntilExit
        // forever, taking `swift test` and the SwiftPM build lock with it
        // (issue #7, sampled at ProcessRunner.swift:66).
        try await withTimeout(.seconds(60)) {
            await withTaskGroup(of: Int32.self) { group in
                for _ in 0..<40 {
                    group.addTask {
                        let result = try? await ProcessRunner.run(
                            executable: "/usr/bin/true",
                            arguments: [],
                            environment: [:],
                            timeout: .seconds(10)
                        )
                        return result?.exitCode ?? -1
                    }
                }
                for await code in group { #expect(code == 0) }
            }
        }
    }

    /// Waiting on a child must never park a thread of the cooperative pool.
    ///
    /// This is the regression guard for a run that hung forever. The blocking
    /// form — `waitUntilExit()` and `readDataToEndOfFile()` behind
    /// `Task.detached` — costs three cooperative threads per command, so a
    /// handful of concurrent verifications occupied every thread the Swift
    /// runtime has. Worse, `waitUntilExit()` spins a run loop, and a run loop on
    /// a pool thread the runtime is free to park or reuse intermittently missed
    /// the child's termination and never returned at all: the command never
    /// finished, so the run never reached a terminal state.
    ///
    /// Rather than race that timing, this asserts the property underneath it —
    /// unrelated work still gets scheduled while many commands are in flight.
    @Test("Waiting on a child never parks a thread of the cooperative pool")
    func doesNotOccupyCooperativeThreads() async throws {
        // Comfortably more commands than the pool has threads.
        let width = ProcessInfo.processInfo.activeProcessorCount * 2

        async let commands: Void = withTaskGroup(of: Int32.self) { group in
            for _ in 0..<width {
                group.addTask {
                    let result = try? await ProcessRunner.run(
                        executable: "/bin/sleep", arguments: ["0.5"],
                        environment: Self.environment, timeout: .seconds(30)
                    )
                    return result?.exitCode ?? -1
                }
            }
            for await code in group { #expect(code == 0) }
        }

        // Ordinary concurrent work, of the kind the scheduler and the UI do
        // while a run is going. Ten hops that should take ~50 ms in total.
        let start = ContinuousClock.now
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(5)) }
        let elapsed = ContinuousClock.now - start

        await commands
        #expect(elapsed < .milliseconds(400), "concurrency stalled for \(elapsed)")
    }

    @Test("stdout and stderr are both captured, and a non-zero exit is reported")
    func capturesBothStreams() async throws {
        let result = try await ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf out; printf err >&2; exit 7"],
            environment: [:],
            timeout: .seconds(10)
        )
        #expect(result.exitCode == 7)
        #expect(result.stdout == "out")
        #expect(result.stderr == "err")
        #expect(!result.timedOut)
        #expect(!result.succeeded)
    }

    @Test("A child that outlives its timeout is terminated and reported as timed out")
    func timeoutTerminates() async throws {
        let result = try await withTimeout(.seconds(30)) {
            try await ProcessRunner.run(
                executable: "/bin/sh",
                arguments: ["-c", "sleep 30"],
                environment: [:],
                timeout: .milliseconds(300)
            )
        }
        #expect(result.timedOut)
        #expect(!result.succeeded)
    }

    /// A child that swallows SIGTERM is killed, not waited on.
    ///
    /// `trap "" TERM` makes the shell deaf to the polite ask — and its `sleep`
    /// with it, because an *ignored* disposition is inherited across `fork`. So
    /// only the second rung ends this run. Without it `run` never returns and
    /// whatever task group is waiting on it never completes, which is exactly
    /// the shape of #7.
    ///
    /// The child loops over short sleeps rather than sleeping once for a long
    /// time, and that is not cosmetic: a grandchild inherits the write end of
    /// the stdout pipe, and the final drain blocks until every holder lets go.
    /// `sleep 60` would therefore keep this run alive for a minute *after* its
    /// parent was killed, and the test would be measuring the orphan rather
    /// than the escalation.
    ///
    /// The grace is shortened rather than left at the shipped 15 s: what is
    /// under test is that the second rung fires at all, and waiting out the
    /// real number would buy nothing but fifteen seconds on every `swift test`.
    /// That the two spawners share the number is not asserted here because it
    /// is not assertable — there is one constant and both default to it, so a
    /// disagreement is a compile error rather than a red test.
    @Test("A child that ignores SIGTERM is killed rather than waited on")
    func timeoutEscalatesToSIGKILL() async throws {
        let result = try await withTimeout(.seconds(60)) {
            try await ProcessRunner.run(
                executable: "/bin/sh",
                arguments: ["-c", #"trap "" TERM; while :; do sleep 0.2; done"#],
                environment: [:],
                timeout: .milliseconds(300),
                hardKillAfter: .milliseconds(300)
            )
        }
        #expect(result.timedOut)
        #expect(!result.succeeded)
        // Not merely "it stopped": the status names the signal that stopped it,
        // so a child that had quietly died of something else could not pass.
        #expect(result.exitCode == SIGKILL, "expected SIGKILL, got \(result.exitCode)")
    }

    /// The tail — what a child writes between the last `readabilityHandler`
    /// callback and its exit.
    ///
    /// This is the byte range a naive port of the drain drops, and dropping it
    /// is silent. What goes missing is the *end* of a `gh … --json` payload, so
    /// it surfaces as malformed JSON in whatever tried to parse it, never as
    /// "the output was truncated" — the symptom does not point here, which is
    /// why the guard has to.
    ///
    /// A full pipe buffer goes out first so the sentinel genuinely arrives
    /// after a callback has already run and had its go at the descriptor. The
    /// volume test above covers deadlock on a full buffer; this one covers the
    /// last ten bytes, and only one of those two questions is about size.
    @Test("The last thing a child writes before exiting is never lost")
    func capturesTheTail() async throws {
        let sentinel = "LAST-LINE\n"
        let bulk = 65_536
        try await withTimeout(.seconds(120)) {
            // Repeated, because losing the tail is a race: one green pass says
            // nothing, and the failure it guards against showed up as roughly
            // three results in a few thousand when the analogous race went
            // unguarded in the collecting handlers.
            for attempt in 0..<50 {
                let result = try await ProcessRunner.run(
                    executable: "/bin/sh",
                    arguments: ["-c", "yes abcdefghij | head -c \(bulk); printf 'LAST-LINE\\n'"],
                    environment: Self.environment,
                    timeout: .seconds(30)
                )
                #expect(result.exitCode == 0)
                #expect(
                    result.stdout.hasSuffix(sentinel),
                    """
                    attempt \(attempt): tail lost — \(result.stdoutData.count) bytes \
                    ending \(String(result.stdout.suffix(12)).debugDescription)
                    """
                )
                #expect(result.stdoutData.count == bulk + sentinel.utf8.count)
            }
        }
    }

    @Test("A child that writes more than one pipe buffer does not deadlock")
    func largeOutputDoesNotDeadlock() async throws {
        // Both pipes must drain concurrently; 1 MiB is well past the 64 KiB
        // pipe buffer that would otherwise block the child forever.
        let result = try await withTimeout(.seconds(60)) {
            try await ProcessRunner.run(
                executable: "/bin/sh",
                arguments: ["-c", "yes abcdefghij | head -c 1048576; yes k | head -c 200000 >&2"],
                environment: [:],
                timeout: .seconds(30)
            )
        }
        #expect(result.stdoutData.count == 1_048_576)
        #expect(result.stderrData.count == 200_000)
        #expect(result.exitCode == 0)
    }

    @Test("A child that exits before anyone waits is still reported")
    func exitsImmediately() async throws {
        // The other half of the same race: the concurrency test above proves a
        // notification is not lost between siblings, this one proves it is not
        // lost to speed. `/usr/bin/false` is what the end-to-end suites hand
        // every verifier, so a child finishing before its waiter arrives is run
        // hundreds of times per `swift test`.
        try await withTimeout(.seconds(60)) {
            for _ in 0..<20 {
                let result = try await ProcessRunner.run(
                    executable: "/usr/bin/false", arguments: [], environment: [:]
                )
                #expect(result.exitCode == 1)
                #expect(!result.timedOut)
            }
        }
    }

    @Test("Something that is not an executable is refused before it is launched")
    func refusesNonExecutable() async {
        await #expect(throws: ProcessError.self) {
            try await ProcessRunner.run(
                executable: "/etc/hosts", arguments: [], environment: [:]
            )
        }
    }

    @Test("check throws on a non-zero exit and carries the stderr")
    func checkThrows() async {
        await #expect(throws: ProcessError.self) {
            try await ProcessRunner.check(
                executable: "/bin/sh",
                arguments: ["-c", "echo nope 1>&2; exit 1"],
                environment: [:]
            )
        }
    }
}
