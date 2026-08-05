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

    public var errorDescription: String? {
        switch self {
        case .notExecutable(let path):
            "Not an executable file: \(path)"
        case .failed(let command, let code, let stderr):
            "\(command) exited \(code)\(stderr.isEmpty ? "" : ": \(stderr.prefix(400))")"
        }
    }
}

/// Runs short-lived commands — `gh`, `git`, `zsh -lc` — and collects their
/// output. Long-running agent runs use `StreamingProcess` instead.
public enum ProcessRunner {

    public static func run(
        executable: String,
        arguments: [String],
        cwd: String? = nil,
        environment: [String: String],
        timeout: Duration? = .seconds(60)
    ) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ProcessError.notExecutable(executable)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // Never let a child inherit the app's stdin and block waiting on it.
        process.standardInput = FileHandle.nullDevice

        // Collected as it arrives, and published by the termination handler —
        // the arrangement `StreamingProcess` already uses, for the two reasons
        // it documents. Both pipes must keep draining *while* the child runs or
        // a child that fills one deadlocks; and the exit must be reported by
        // the handler rather than awaited, because `waitUntilExit` spins a run
        // loop on whatever thread calls it and was observed never returning for
        // a child that had already gone. That hang wedged the whole test
        // process roughly one run in three.
        //
        // The handler is installed before `run()`, so a child that exits
        // immediately — the `/usr/bin/false` this is asked for constantly —
        // cannot finish in the gap and leave nobody listening.
        let state = Locked(Wait())
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading

        outHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            state.withLock { $0.stdout.append(chunk) }
        }
        errHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            state.withLock { $0.stderr.append(chunk) }
        }

        process.terminationHandler = { process in
            // Detached before the final drain: they read the same descriptor on
            // their own queue, and racing them against `readDataToEndOfFile`
            // loses the tail.
            outHandle.readabilityHandler = nil
            errHandle.readabilityHandler = nil
            let restOut = outHandle.readDataToEndOfFile()
            let restErr = errHandle.readDataToEndOfFile()

            // Publishing the exit and handing off any waiter happen under one
            // lock, so a caller parking at this instant cannot miss it.
            let handoff = state.withLock { current -> (CheckedContinuation<Exit, Never>, Exit)? in
                current.stdout.append(restOut)
                current.stderr.append(restErr)
                let exit = Exit(
                    code: process.terminationStatus,
                    stdout: current.stdout,
                    stderr: current.stderr
                )
                current.exit = exit
                defer { current.waiter = nil }
                return current.waiter.map { ($0, exit) }
            }
            if let (waiter, exit) = handoff { waiter.resume(returning: exit) }
        }

        try process.run()

        let timedOut = Locked(false)
        let watchdog = timeout.map { limit in
            Task {
                try? await Task.sleep(for: limit)
                guard !Task.isCancelled, process.isRunning else { return }
                timedOut.withLock { $0 = true }
                // Terminating makes the child exit, which fires the handler
                // above — so there is nothing further to wait for here.
                process.terminate()
            }
        }
        let exit = await withCheckedContinuation { continuation in
            // Checked and parked under one lock: the termination handler cannot
            // slip between the two and leave this waiting forever.
            let already = state.withLock { current -> Exit? in
                if let exit = current.exit { return exit }
                current.waiter = continuation
                return nil
            }
            if let already { continuation.resume(returning: already) }
        }
        watchdog?.cancel()

        return ProcessResult(
            exitCode: exit.code,
            stdoutData: exit.stdout,
            stderrData: exit.stderr,
            timedOut: timedOut.value
        )
    }

    private struct Exit: Sendable {
        var code: Int32
        var stdout: Data
        var stderr: Data
    }

    private struct Wait: @unchecked Sendable {
        /// Filled by the readability handlers while the child runs.
        var stdout = Data()
        var stderr = Data()
        var exit: Exit?
        /// Whoever is waiting for the exit, parked under the same lock that
        /// publishes it.
        var waiter: CheckedContinuation<Exit, Never>?
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
