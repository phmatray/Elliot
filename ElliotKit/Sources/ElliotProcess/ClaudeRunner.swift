import ElliotModel
import Foundation

/// Everything needed to spawn one `claude -p`.
public struct ClaudeInvocation: Sendable {
    /// Doubles as `--session-id`, so the CLI's own transcript path is known
    /// before the process emits a byte.
    public var runID: UUID
    public var prompt: String
    public var cwd: String
    public var permissionMode: PermissionMode
    public var extraAllowedTools: [String]
    public var includePartialMessages: Bool

    public init(
        runID: UUID,
        prompt: String,
        cwd: String,
        permissionMode: PermissionMode = .bypassPermissions,
        extraAllowedTools: [String] = [],
        includePartialMessages: Bool = false
    ) {
        self.runID = runID
        self.prompt = prompt
        self.cwd = cwd
        self.permissionMode = permissionMode
        self.extraAllowedTools = extraAllowedTools
        self.includePartialMessages = includePartialMessages
    }

    /// The full argument list, as a pure function so a test can assert the
    /// exact command a drag produces.
    ///
    /// There is no `--cwd` flag: the working directory is set on the spawn.
    public func arguments() -> [String] {
        var args = [
            "-p", prompt,
            "--output-format", "stream-json",
            "--verbose",
            "--permission-mode", permissionMode.rawValue,
            "--session-id", runID.uuidString.lowercased(),
            "--add-dir", cwd,
        ]
        if !extraAllowedTools.isEmpty {
            args += ["--allowedTools", extraAllowedTools.joined(separator: ",")]
        }
        if includePartialMessages {
            args.append("--include-partial-messages")
        }
        return args
    }
}

public struct ClaudeRunOutcome: Sendable {
    public var exitCode: Int32
    public var wasTerminated: Bool
    /// The terminal `result` event — the same object `--output-format json`
    /// would have returned on its own.
    public var result: RunResult?
    public var stderr: String

    public init(exitCode: Int32, wasTerminated: Bool, result: RunResult?, stderr: String) {
        self.exitCode = exitCode
        self.wasTerminated = wasTerminated
        self.result = result
        self.stderr = stderr
    }

    /// SIGTERM shutdown. Claude Code documents exit 143 for it.
    public var wasSignalled: Bool { exitCode == 143 || wasTerminated }
}

public enum RunUpdate: Sendable {
    case started(pid: Int32)
    case event(StreamEvent)
    /// No output for longer than the idle window. The run is still alive; the
    /// user decides whether to keep waiting.
    case stalled(since: Date)
    case finished(ClaudeRunOutcome)
}

/// One live `claude -p`, streaming its events and writing its raw log.
public final class ClaudeRun: Sendable {
    private let process: StreamingProcess
    public let updates: AsyncStream<RunUpdate>
    public let arguments: [String]

    public var processIdentifier: Int32 { process.processIdentifier }

    /// Asks the run to stop. Safe to call after it has already finished.
    public func cancel() { process.terminate() }

    fileprivate init(process: StreamingProcess, updates: AsyncStream<RunUpdate>, arguments: [String]) {
        self.process = process
        self.updates = updates
        self.arguments = arguments
    }

    public static func start(
        invocation: ClaudeInvocation,
        config: ToolConfig,
        logURL: URL,
        idleTimeout: Duration = .seconds(20 * 60)
    ) throws -> ClaudeRun {
        let arguments = invocation.arguments()

        // The durable sink is a file, not the database: the UI stream is
        // bounded and may drop, this never does.
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        let handleBox = Locked<FileHandle?>(logHandle)

        let lastOutput = Locked(Date())
        let announcedStall = Locked(false)

        var continuation: AsyncStream<RunUpdate>.Continuation!
        let updates = AsyncStream<RunUpdate>(bufferingPolicy: .bufferingNewest(512)) { continuation = $0 }
        let updateContinuation = continuation!

        let process = try StreamingProcess(
            executable: config.claudePath,
            arguments: arguments,
            cwd: invocation.cwd,
            environment: config.environment,
            stdoutMirror: { chunk in
                handleBox.withLock { $0?.write(chunk) }
                lastOutput.withLock { $0 = Date() }
                announcedStall.withLock { $0 = false }
            }
        )

        updateContinuation.yield(.started(pid: process.processIdentifier))

        // Decode lines into events.
        let decodeTask = Task {
            for await line in process.lines {
                guard let event = StreamEventDecoder.decode(line: line) else { continue }
                updateContinuation.yield(.event(event))
            }
        }

        // Watch for silence. There is deliberately no wall-clock kill: waiting
        // hours on CI is legitimate for merge-pr. Silence is the useful signal.
        let idleTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                let since = lastOutput.withLock { $0 }
                let quietFor = Date().timeIntervalSince(since)
                if quietFor > Double(idleTimeout.components.seconds) {
                    let shouldAnnounce = announcedStall.withLock { announced -> Bool in
                        guard !announced else { return false }
                        announced = true
                        return true
                    }
                    if shouldAnnounce { updateContinuation.yield(.stalled(since: since)) }
                }
            }
        }

        Task {
            let exit = await process.waitForExit()
            _ = await decodeTask.result      // let the last events through first
            idleTask.cancel()
            handleBox.withLock { handle in
                try? handle?.close()
                handle = nil
            }

            // The terminal result is recovered from the log rather than kept in
            // memory, so a run that crashed the decoder still reports honestly.
            let result = Self.lastResult(inLogAt: logURL)
            updateContinuation.yield(.finished(ClaudeRunOutcome(
                exitCode: exit.code,
                wasTerminated: exit.wasTerminated,
                result: result,
                stderr: exit.stderr
            )))
            updateContinuation.finish()
        }

        return ClaudeRun(process: process, updates: updates, arguments: arguments)
    }

    /// Scans a run log backwards for the terminal `result` event.
    static func lastResult(inLogAt url: URL) -> RunResult? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        for line in data.split(separator: 0x0A).reversed() {
            if case .result(let result)? = StreamEventDecoder.decode(line: Data(line)) {
                return result
            }
        }
        return nil
    }
}
