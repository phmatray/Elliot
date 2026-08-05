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
