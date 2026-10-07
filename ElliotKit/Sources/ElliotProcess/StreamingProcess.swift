import Foundation

/// A long-running child whose stdout is consumed line by line as it arrives.
///
/// ⚠️ **No production consumer since Stage 1 of #379.** `ClaudeRunner` was its only caller, and it
/// was deleted with the CLI runner; the sole remaining construction site is
/// `StreamingProcessDrainTests`. It is kept anyway because
/// `DrainDuplicationTests.commentsAreNotDuplicated` reads this file against `ProcessRunner.swift`
/// — that intersection is #146's runnable receipt — and because `ACPTransport` is modelled on it.
/// Deleting it means re-pointing that gate at `ACPTransport.swift` and deciding what becomes of
/// `StreamingProcessDrainTests`, which is a change with its own argument and not a tidy-up to fold
/// into this one.
///
/// Filed as **#384**, *"Delete StreamingProcess and re-point the #146 gate at ACPTransport"*, so
/// this note routes to work rather than saying somebody should. Measured there, with the gate's own
/// normalisation: `ProcessRunner` ∩ `StreamingProcess` and `ProcessRunner` ∩ `ACPTransport` are
/// **both empty today**, so re-pointing costs no cleanup — but a zero is the passing state, not
/// evidence the new pair is the one whose duplication is worth fearing. That judgement, and the
/// fate of `StreamingProcessDrainTests`, are what #384 is for.
///
/// Cancellation is a plain `terminate()` (SIGTERM) — and that already reaches
/// the whole process group. Measured directly (`bash -c 'sleep 300 & sleep
/// 300'`, and this package's own `fake-claude.sh` in `FAKE_CLAUDE_MODE=hang`,
/// both spawned through `Process` and stopped with `terminate()`): an ordinary
/// descendant that shares the child's process group dies in the same instant
/// the child does. Only a descendant that has called `setsid()` and moved
/// itself into its own session survives — orphaned, reparented to pid 1.
/// There is no "reach into the process group by hand" left to do; Foundation
/// already does it. Claude Code's own handling of the signal — aborting the
/// turn, running its SessionEnd hooks, exiting 143 — happens in its own
/// process, not as a prerequisite for its ordinary Bash children's exit.
///
/// `ChildProcess` owns the spawn, the drain and the exit. What remains here is
/// this spawner's own idea — that stdout is a sequence of lines.
public final class StreamingProcess: Sendable {
    private let child: ChildProcess<LineSink>

    /// Turns chunks into lines. Called under `ChildProcess`'s lock, which is
    /// what stops a handler caught mid-flight by the child's exit yielding into
    /// a stream the final drain has already finished — the failure that arrives
    /// as an entire run being empty.
    ///
    /// That lock is therefore held across `mirror`, a synchronous write to the
    /// run's log file. It is the reason `ChildProcess` never consults it from
    /// the SIGKILL backstop.
    private struct LineSink: ChildOutputSink {
        var buffer = LineBuffer()
        var stderr = Data()
        let mirror: (@Sendable (Data) -> Void)?
        let continuation: AsyncStream<Data>.Continuation

        mutating func receiveStdout(_ chunk: Data) {
            // The durable sink gets the raw bytes before anything is parsed,
            // so a decoding bug can never lose an event.
            mirror?(chunk)
            for line in buffer.append(chunk) { continuation.yield(line) }
        }

        mutating func receiveStderr(_ chunk: Data) { stderr.append(chunk) }

        mutating func finish() {
            // A process that ended without a trailing newline still has one
            // last event waiting in the buffer.
            if let tail = buffer.flush(), !tail.isEmpty { continuation.yield(tail) }
            continuation.finish()
        }
    }

    public struct Exit: Sendable {
        public var code: Int32
        public var stderr: String
        /// Set when the caller asked for termination rather than the process
        /// ending on its own.
        public var wasTerminated: Bool
    }

    /// Complete stdout lines, in order, as the child emits them. The stream
    /// finishes when the process exits and the last partial line is flushed.
    public let lines: AsyncStream<Data>

    public init(
        executable: String,
        arguments: [String],
        cwd: String,
        environment: [String: String],
        stdoutMirror: (@Sendable (Data) -> Void)? = nil
    ) throws {
        var continuation: AsyncStream<Data>.Continuation!
        lines = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }

        child = try ChildProcess(
            executable: executable,
            arguments: arguments,
            cwd: cwd,
            environment: environment,
            sink: LineSink(mirror: stdoutMirror, continuation: continuation!)
        )
    }

    public var isRunning: Bool { child.isRunning }
    public var processIdentifier: Int32 { child.processIdentifier }

    /// Waits for the child to exit.
    public func waitForExit() async -> Exit {
        let termination = await child.wait()
        // Read after the exit is published, so the stderr this reports is the
        // whole of it — the final drain's bytes included.
        return Exit(
            code: termination.code,
            stderr: child.withSink { String(decoding: $0.stderr, as: UTF8.self) },
            wasTerminated: termination.wasTerminated
        )
    }

    /// Asks the child to stop, escalating only if it ignores the request.
    ///
    /// SIGTERM first because Claude Code shuts itself down cleanly on it;
    /// SIGKILL is the backstop for a process that is wedged.
    public func terminate(hardKillAfter grace: Duration = ProcessTermination.hardKillGrace) {
        child.terminate(hardKillAfter: grace)
    }
}
