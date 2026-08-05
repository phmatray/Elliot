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

/// The exit flag and whoever is waiting on it, under one lock.
///
/// Both live together for the same reason `StreamingProcess.State` does: a
/// waiter that checks the flag and parks in two separate steps can be handed
/// off to *after* the handler has already run, and then waits forever.
private struct WaitState: @unchecked Sendable {
    var exited = false
    var waiter: CheckedContinuation<Void, Never>?
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

        // Foundation's `waitUntilExit()` spins a run loop waiting for a
        // notification that a concurrently-spawned sibling can consume first.
        // It then parks forever — and because it is called from a detached
        // task, it parks a *cooperative-pool* thread, which is how one wedged
        // `gh` call took `swift test` and the SwiftPM build lock down with it
        // (issue #7, sampled at this line, with no child process left alive).
        //
        // `StreamingProcess` already avoids it: publish the exit from
        // `terminationHandler` and hand off the waiter under ONE lock, so a
        // waiter arriving at that exact instant cannot miss it. Same mechanism
        // here, so the two spawners cannot diverge. Must be installed before
        // `run()`, or a fast child can exit before the handler exists.
        let waitState = Locked(WaitState())
        process.terminationHandler = { _ in
            let parked = waitState.withLock { current -> CheckedContinuation<Void, Never>? in
                current.exited = true
                defer { current.waiter = nil }
                return current.waiter
            }
            parked?.resume()
        }

        // Only ever awaited sequentially (the group arm, then the post-timeout
        // reap), so a single waiter slot is enough.
        let waitForExit: @Sendable () async -> Void = {
            await withCheckedContinuation { continuation in
                let alreadyExited = waitState.withLock { current -> Bool in
                    if current.exited { return true }
                    current.waiter = continuation
                    return false
                }
                if alreadyExited { continuation.resume() }
            }
        }

        try process.run()

        // Both pipes must be drained concurrently: a child that fills one while
        // we block on the other deadlocks.
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        async let outData = Task.detached { outHandle.readDataToEndOfFile() }.value
        async let errData = Task.detached { errHandle.readDataToEndOfFile() }.value

        let timedOut = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await waitForExit()
                return false
            }
            if let timeout {
                group.addTask {
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled, process.isRunning else { return false }
                    process.terminate()
                    return true
                }
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        // If the timeout fired, wait for the terminate to actually land.
        if timedOut { await waitForExit() }

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdoutData: await outData,
            stderrData: await errData,
            timedOut: timedOut
        )
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
