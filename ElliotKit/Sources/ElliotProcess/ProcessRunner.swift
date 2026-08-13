import Foundation

public struct ProcessResult: Sendable {
    public var exitCode: Int32
    public var stdoutData: Data
    public var stderrData: Data
    public var timedOut: Bool

    public var stdout: String { String(decoding: stdoutData, as: UTF8.self) }
    public var stderr: String { String(decoding: stderrData, as: UTF8.self) }
    public var succeeded: Bool { exitCode == 0 && !timedOut }
}

public enum ProcessError: Error, LocalizedError {
    case notExecutable(String)
    case failed(command: String, exitCode: Int32, stderr: String)
    case stdinNotPiped
    case stdinClosed
    /// `fcntl(F_SETNOSIGPIPE)` on the stdin pipe's write descriptor returned nonzero. See
    /// `ChildProcess.init`'s `.pipe` arm for what this guard exists to prevent — a silent failure
    /// here would hand back exactly the process-fatal behaviour it is meant to remove.
    case stdinSigPipeGuardFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .notExecutable(let path):
            "Not an executable file: \(path)"
        case .failed(let command, let code, let stderr):
            "\(command) exited \(code)\(stderr.isEmpty ? "" : ": \(stderr.prefix(400))")"
        case .stdinNotPiped:
            "This child was spawned with stdin closed. Pass `stdin: .pipe` to write to it."
        case .stdinClosed:
            "This child's stdin has already been closed."
        case .stdinSigPipeGuardFailed(let code):
            "Could not disable SIGPIPE on this child's stdin pipe (fcntl F_SETNOSIGPIPE): "
                + "\(String(cString: strerror(code))) (\(code))"
        }
    }
}

/// Runs short-lived commands — `gh`, `git`, `zsh -lc` — and collects their
/// output. Long-running agent runs use `StreamingProcess` instead.
///
/// The spawn, the drain and the exit belong to `ChildProcess`; what is left here
/// is this runner's own two ideas — a timeout, and a `ProcessResult`.
public enum ProcessRunner {

    /// Keeps the bytes, and nothing else. Called under `ChildProcess`'s lock.
    private struct CollectingSink: ChildOutputSink {
        var stdout = Data()
        var stderr = Data()

        mutating func receiveStdout(_ chunk: Data) { stdout.append(chunk) }
        mutating func receiveStderr(_ chunk: Data) { stderr.append(chunk) }
        /// Nothing to close out: a `Data` is complete after its last append.
        mutating func finish() {}
    }

    public static func run(
        executable: String,
        arguments: [String],
        cwd: String? = nil,
        environment: [String: String],
        timeout: Duration? = .seconds(60),
        hardKillAfter: Duration = ProcessTermination.hardKillGrace
    ) async throws -> ProcessResult {
        let child = try ChildProcess(
            executable: executable, arguments: arguments, cwd: cwd,
            environment: environment, sink: CollectingSink()
        )

        let timedOut = await withTaskGroup(of: Bool.self) { group in
            group.addTask { _ = await child.wait(); return false }
            if let timeout {
                group.addTask {
                    do { try await Task.sleep(for: timeout) } catch { return false }
                    guard child.isRunning else { return false }
                    // SIGTERM, then SIGKILL for a command that ignores it: the
                    // exit is awaited below, so without the second rung a
                    // wedged `gh` would be the very hang this file prevents.
                    // Measured, with the escalation deleted: `swift test` had
                    // no verdict 5 minutes 39 seconds later. The rung and its
                    // grace are `StreamingProcess`'s too — the two spawners
                    // must not disagree about when a child is hopeless.
                    //
                    // This is the one place where sharing the mechanism changed
                    // behaviour rather than moving lines, and it is invisible in
                    // the diff: `ProcessRunner` used to answer the liveness
                    // question with `state.withLock { !$0.exited } && …`, and
                    // `ChildProcess` asks `process.isRunning` alone, because a
                    // sink may hold that lock across a write to the run's log.
                    // Nothing is lost. The flag was set inside the termination
                    // handler, which only runs once Foundation has reaped the
                    // child, so `isRunning` had gone false strictly earlier: the
                    // extra term could never have vetoed a kill this one allows.
                    // Its own comment conceded that, calling it "belt and
                    // braces, not a guarantee". `timeoutEscalatesToSIGKILL` is
                    // what keeps the claim honest.
                    child.terminate(hardKillAfter: hardKillAfter)
                    return true
                }
            }
            let first = await group.next() ?? false
            // The exit is still awaited on the way out of the group, so a
            // timeout returns only once the terminate has actually landed.
            group.cancelAll()
            return first
        }

        // The group cannot return until the waiting task above has, and that
        // task returns only once the exit is published — so this finds it
        // already there rather than parking again.
        let termination = await child.wait()
        return child.withSink { sink in
            ProcessResult(
                exitCode: termination.code,
                stdoutData: sink.stdout,
                stderrData: sink.stderr,
                timedOut: timedOut
            )
        }
    }

    /// Runs a command and throws unless it exits 0.
    @discardableResult
    public static func check(
        executable: String,
        arguments: [String],
        cwd: String? = nil,
        environment: [String: String],
        timeout: Duration? = .seconds(60)
    ) async throws -> ProcessResult {
        let result = try await run(
            executable: executable, arguments: arguments,
            cwd: cwd, environment: environment, timeout: timeout
        )
        guard result.succeeded else {
            throw ProcessError.failed(
                command: ([executable] + arguments).joined(separator: " "),
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
        return result
    }
}
