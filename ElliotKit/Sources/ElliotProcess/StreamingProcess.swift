import Foundation

/// A long-running child whose stdout is consumed line by line as it arrives.
///
/// Cancellation is a plain `terminate()` (SIGTERM). Claude Code handles that
/// signal itself: it aborts the turn, **terminates the process tree of any
/// running Bash command**, runs its SessionEnd hooks and exits 143. Reaching
/// into the process group by hand would only pre-empt that orderly shutdown —
/// and cost `git` the chance to release `index.lock`.
public final class StreamingProcess: Sendable {
    private let process: Process
    private let state = Locked(State())

    private struct State {
        var buffer = LineBuffer()
        var stderr = Data()
        var finished = false
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

    private let exitContinuation = Locked<CheckedContinuation<Exit, Never>?>(nil)
    private let terminationRequested = Locked(false)

    public init(
        executable: String,
        arguments: [String],
        cwd: String,
        environment: [String: String],
        stdoutMirror: (@Sendable (Data) -> Void)? = nil
    ) throws {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ProcessError.notExecutable(executable)
        }

        process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let state = self.state
        var continuation: AsyncStream<Data>.Continuation!
        lines = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        let lineContinuation = continuation!

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            // The durable sink gets the raw bytes before anything is parsed, so
            // a decoding bug can never lose an event.
            stdoutMirror?(chunk)
            let complete = state.withLock { $0.buffer.append(chunk) }
            for line in complete { lineContinuation.yield(line) }
        }

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            state.withLock { $0.stderr.append(chunk) }
        }

        let exitContinuation = self.exitContinuation
        let terminationRequested = self.terminationRequested
        process.terminationHandler = { process in
            // Drain whatever is still buffered in the pipes before closing.
            let rest = outPipe.fileHandleForReading.readDataToEndOfFile()
            if !rest.isEmpty {
                stdoutMirror?(rest)
                let complete = state.withLock { $0.buffer.append(rest) }
                for line in complete { lineContinuation.yield(line) }
            }
            let restErr = errPipe.fileHandleForReading.readDataToEndOfFile()

            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil

            // A process that ended without a trailing newline still has a final
            // event waiting.
            let tail = state.withLock { current -> Data? in
                current.stderr.append(restErr)
                current.finished = true
                return current.buffer.flush()
            }
            if let tail, !tail.isEmpty { lineContinuation.yield(tail) }
            lineContinuation.finish()

            let stderr = state.withLock { String(decoding: $0.stderr, as: UTF8.self) }
            let exit = Exit(
                code: process.terminationStatus,
                stderr: stderr,
                wasTerminated: terminationRequested.withLock { $0 }
            )
            exitContinuation.withLock { pending in
                pending?.resume(returning: exit)
                pending = nil
            }
        }

        try process.run()
    }

    public var isRunning: Bool { process.isRunning }
    public var processIdentifier: Int32 { process.processIdentifier }

    /// Waits for the child to exit.
    public func waitForExit() async -> Exit {
        await withCheckedContinuation { continuation in
            let alreadyDone = state.withLock { $0.finished }
            if alreadyDone {
                let stderr = state.withLock { String(decoding: $0.stderr, as: UTF8.self) }
                continuation.resume(returning: Exit(
                    code: process.terminationStatus,
                    stderr: stderr,
                    wasTerminated: terminationRequested.withLock { $0 }
                ))
                return
            }
            exitContinuation.withLock { $0 = continuation }
        }
    }

    /// Asks the child to stop, escalating only if it ignores the request.
    ///
    /// SIGTERM first because Claude Code shuts itself down cleanly on it;
    /// SIGKILL is the backstop for a process that is wedged.
    public func terminate(hardKillAfter grace: Duration = .seconds(15)) {
        guard process.isRunning else { return }
        terminationRequested.withLock { $0 = true }
        process.terminate()

        let process = self.process
        Task.detached {
            try? await Task.sleep(for: grace)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}
