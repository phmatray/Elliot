import Foundation
import TestSupport
import Testing

@testable import ElliotProcess

@Suite("Process runner")
struct ProcessRunnerTests {

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
