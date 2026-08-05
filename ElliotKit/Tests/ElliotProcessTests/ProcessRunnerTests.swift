import Foundation
import Testing

@testable import ElliotProcess

private let cleanEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

@Suite("Process runner")
struct ProcessRunnerTests {

    @Test("A command's output and exit code come back whole")
    func collectsOutput() async throws {
        let result = try await ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf hello; printf oops 1>&2; exit 3"],
            environment: cleanEnvironment
        )
        #expect(result.stdout == "hello")
        #expect(result.stderr == "oops")
        #expect(result.exitCode == 3)
        #expect(!result.timedOut)
        #expect(!result.succeeded)
    }

    @Test("A child that outlives its window is terminated and said to have been")
    func timesOut() async throws {
        let result = try await ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 30"],
            environment: cleanEnvironment,
            timeout: .milliseconds(300)
        )
        #expect(result.timedOut)
        #expect(!result.succeeded)
    }

    @Test("More output than a pipe holds does not deadlock")
    func drainsWhileTheChildIsStillWriting() async throws {
        // A pipe buffers 64 KiB. A child writing past that blocks in `write`
        // until someone reads, so a runner that only drains after the child has
        // exited waits forever for a child waiting for it. This is the test
        // that catches that inversion.
        let result = try await ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "/usr/bin/head -c 400000 /dev/zero | /usr/bin/tr '\\0' 'x'"],
            environment: cleanEnvironment,
            timeout: .seconds(20)
        )
        #expect(result.stdoutData.count == 400_000)
        #expect(result.succeeded)
    }

    @Test("A child that exits before anyone waits is still reported")
    func exitsImmediately() async throws {
        // `/usr/bin/false` is what the end-to-end tests hand every verifier, so
        // this race is run hundreds of times per suite.
        for _ in 0..<20 {
            let result = try await ProcessRunner.run(
                executable: "/usr/bin/false", arguments: [], environment: cleanEnvironment
            )
            #expect(result.exitCode == 1)
            #expect(!result.timedOut)
        }
    }

    @Test("Something that is not an executable is refused before it is launched")
    func refusesNonExecutable() async {
        await #expect(throws: ProcessError.self) {
            try await ProcessRunner.run(
                executable: "/etc/hosts", arguments: [], environment: cleanEnvironment
            )
        }
    }

    @Test("check throws on a non-zero exit and carries the stderr")
    func checkThrows() async {
        await #expect(throws: ProcessError.self) {
            try await ProcessRunner.check(
                executable: "/bin/sh",
                arguments: ["-c", "echo nope 1>&2; exit 1"],
                environment: cleanEnvironment
            )
        }
    }
}
