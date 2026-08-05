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
