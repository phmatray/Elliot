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

    private struct State: @unchecked Sendable {
        var buffer = LineBuffer()
        var stderr = Data()
        var finished = false
        var exit: Exit?
        /// Whoever is waiting for the exit, parked under the same lock that
        /// publishes it.
        var waiter: CheckedContinuation<Exit, Never>?
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

        let terminationRequested = self.terminationRequested
        process.terminationHandler = { process in
            // Detach the handlers *before* draining. They read the same
            // descriptor on their own queue, and racing them against
            // `readDataToEndOfFile` intermittently swallows the final events of
            // a run — which is exactly the tail that carries the result.
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil

            let rest = outPipe.fileHandleForReading.readDataToEndOfFile()
            if !rest.isEmpty {
                stdoutMirror?(rest)
                let complete = state.withLock { $0.buffer.append(rest) }
                for line in complete { lineContinuation.yield(line) }
            }
            let restErr = errPipe.fileHandleForReading.readDataToEndOfFile()

            // A process that ended without a trailing newline still has one
            // last event waiting in the buffer.
            let tail = state.withLock { current -> Data? in
                current.stderr.append(restErr)
                return current.buffer.flush()
            }
            if let tail, !tail.isEmpty { lineContinuation.yield(tail) }
            lineContinuation.finish()

            let exit = Exit(
                code: process.terminationStatus,
                stderr: state.withLock { String(decoding: $0.stderr, as: UTF8.self) },
                wasTerminated: terminationRequested.withLock { $0 }
            )
            // Publishing the exit and handing off any waiter happen under one
            // lock, so a `waitForExit` arriving at this instant cannot miss it
            // and hang forever.
            let waiter = state.withLock { current -> CheckedContinuation<Exit, Never>? in
                current.finished = true
                current.exit = exit
                defer { current.waiter = nil }
                return current.waiter
            }
            waiter?.resume(returning: exit)
        }

        try process.run()
    }

    public var isRunning: Bool { process.isRunning }
    public var processIdentifier: Int32 { process.processIdentifier }

    /// Waits for the child to exit.
    public func waitForExit() async -> Exit {
        await withCheckedContinuation { continuation in
            // Checking and parking under one lock: the termination handler
            // cannot slip between them and leave this waiting forever.
            let alreadyExited = state.withLock { current -> Exit? in
                if let exit = current.exit { return exit }
                current.waiter = continuation
                return nil
            }
            if let alreadyExited { continuation.resume(returning: alreadyExited) }
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
