import Foundation
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
}
