import Foundation
import TestSupport
import Testing

@testable import ElliotProcess

/// Whether `StreamingProcess`'s drain can lose the tail of a child's output.
///
/// The suspicion #26 exists to settle. Stdout is read from two places: a
/// `readabilityHandler` while the child runs, and a final `readDataToEndOfFile`
/// once it exits. If both can be live at the moment of exit, the bytes in flight
/// go to whichever wins. That would not lose a middle line nobody reads — it
/// would lose the **last** one, which in a real run is the terminal `result`
/// event carrying `subtype`, `permission_denials` and the cost, and which
/// `RunScheduler.finish` judges the whole run by.
///
/// The probe is therefore shaped to make the tail as loseable as it can be: a
/// child that writes far more than the pipe can hold and then exits at once,
/// with a distinctive final line, repeated enough times to sample the window.
///
/// Every wait is bounded through `withTimeout`, and nothing here asserts a
/// duration — a race that fails to reproduce must not turn into a hang, and a
/// wall-clock assertion would fail under load while the code behaved perfectly.
@Suite("Streaming process drain", .serialized)
struct StreamingProcessDrainTests {

    /// How many times each shape is sampled.
    ///
    /// Thirty, sized against measured detection rates rather than picked round.
    /// Both historical shapes of this defect were reintroduced and sampled (the
    /// numbers are on #26): a single iteration of the burst tests caught the
    /// original ordering bug 60 times out of 60, and the narrower window that
    /// replaced it 57 and 36 times out of 60. Taking the worst of those — 0.6
    /// per iteration — thirty iterations miss it with probability 0.4³⁰, about
    /// one in 10¹².
    ///
    /// Sixty was the investigation's number and cost 3.3 s; thirty costs 1.0 s,
    /// which is what a guard that runs on every `swift test` can afford. Raise
    /// it here, temporarily, if you are hunting rather than guarding.
    private let iterations = 30

    /// Comfortably longer than a run of these takes, and short enough that a
    /// wedged child fails the test rather than parking the build lock.
    private let bound = Duration.seconds(30)

    /// A child that floods the pipe and then exits with a distinctive last line.
    ///
    /// The size is chosen against the pipe rather than picked round: this
    /// machine reports an 8 KiB pipe buffer (`sysctl net.local.stream.sendspace`),
    /// and 4 000 numbered lines is roughly 19 KiB, so the child cannot have been
    /// fully read at the moment it exits. That unread remainder is the only
    /// state in which the handler and the final drain can contend at all.
    private func flood(_ script: String) throws -> StreamingProcess {
        try StreamingProcess(
            executable: "/bin/sh",
            arguments: ["-c", script],
            cwd: NSTemporaryDirectory(),
            environment: ["PATH": "/usr/bin:/bin"]
        )
    }

    private func collect(_ process: StreamingProcess) async throws -> [String] {
        try await withTimeout(bound) {
            var out: [String] = []
            for await line in process.lines {
                out.append(String(decoding: line, as: UTF8.self))
            }
            return out
        }
    }

    @Test("A burst larger than the pipe arrives whole, last line included")
    func tailSurvivesABurstEndingInANewline() async throws {
        let burst = 4_000
        let sentinel = "ELLIOT-TERMINAL-EVENT"
        let expected = (1...burst).map(String.init) + [sentinel]

        for iteration in 1...iterations {
            let process = try flood("seq 1 \(burst); echo \(sentinel)")
            let lines = try await collect(process)
            let exit = await process.waitForExit()

            #expect(exit.code == 0, "iteration \(iteration)")
            // The whole sequence, not just the count: this catches a lost tail,
            // a duplicated chunk and a reordering with one assertion, and the
            // three failure modes are indistinguishable by count alone.
            #expect(lines == expected, "iteration \(iteration) saw \(lines.count) lines")
        }
    }

    @Test("A burst whose last line has no newline still delivers that line")
    func tailSurvivesABurstWithoutATrailingNewline() async throws {
        // The other half of the drain. A child that ends mid-line leaves its
        // last event in `LineBuffer.pending`, and only the `flush()` inside the
        // termination handler can emit it — a different code path from the one
        // above, and the one where "the last event" is most obviously at risk.
        let burst = 4_000
        let sentinel = "ELLIOT-UNTERMINATED-TAIL"
        let expected = (1...burst).map(String.init) + [sentinel]

        for iteration in 1...iterations {
            let process = try flood("seq 1 \(burst); printf %s \(sentinel)")
            let lines = try await collect(process)
            let exit = await process.waitForExit()

            #expect(exit.code == 0, "iteration \(iteration)")
            #expect(lines == expected, "iteration \(iteration) saw \(lines.count) lines")
        }
    }

    @Test("A child that exits immediately after one line still delivers it")
    func tailSurvivesAnImmediateExit() async throws {
        // The opposite extreme, and the one that most resembles a run whose
        // terminal event is the only thing still in the pipe: no burst to keep
        // the handler busy, so the write and the exit are as close together as
        // the shell can put them.
        for iteration in 1...iterations {
            let process = try flood("echo ELLIOT-ONLY-LINE")
            let lines = try await collect(process)
            let exit = await process.waitForExit()

            #expect(exit.code == 0, "iteration \(iteration)")
            #expect(lines == ["ELLIOT-ONLY-LINE"], "iteration \(iteration)")
        }
    }

    @Test("Stderr is drained whole as well, and does not disturb stdout")
    func stderrIsDrainedToo() async throws {
        // Both descriptors are drained by the same handler under the same lock,
        // so a race on one would show as loss on either. Asserting them together
        // is what makes that visible rather than half-covered.
        for iteration in 1...iterations {
            let process = try flood("seq 1 500; echo OUT-LAST; seq 1 500 >&2; printf %s ERR-LAST >&2")
            let lines = try await collect(process)
            let exit = await process.waitForExit()

            #expect(exit.code == 0, "iteration \(iteration)")
            #expect(lines == (1...500).map(String.init) + ["OUT-LAST"], "iteration \(iteration)")
            #expect(exit.stderr.hasSuffix("ERR-LAST"), "iteration \(iteration)")
            #expect(exit.stderr.hasPrefix("1\n2\n"), "iteration \(iteration)")
        }
    }
}
