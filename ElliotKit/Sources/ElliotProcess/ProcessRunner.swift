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

        try process.run()

        // Both pipes must be drained concurrently: a child that fills one while
        // we block on the other deadlocks.
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        async let outData = Task.detached { outHandle.readDataToEndOfFile() }.value
        async let errData = Task.detached { errHandle.readDataToEndOfFile() }.value

        let timedOut = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await Task.detached { process.waitUntilExit() }.value
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
        if timedOut { await Task.detached { process.waitUntilExit() }.value }

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
