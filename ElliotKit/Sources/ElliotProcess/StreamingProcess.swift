import Foundation

/// A long-running child whose stdout is consumed line by line as it arrives.
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
public final class StreamingProcess: Sendable {
    private let process: Process
    private let state = Locked(State())

    private struct State: @unchecked Sendable {
        var buffer = LineBuffer()
        var stderr = Data()
        var finished = false
        /// Set once the final drain has run. Past this point the descriptors are
        /// spent and the line stream is closed, so nothing may read or yield.
        var drained = false
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

        // Reading the descriptor, buffering it and yielding it all happen under
        // one lock, here and in the final drain below. Clearing a
        // `readabilityHandler` does not wait for one that is already running, so
        // the lock is the only thing that orders the two: without it a handler
        // caught mid-flight by the child's exit yields its lines *after* the
        // drain has finished the stream, and an entire run arrives empty.
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let spent = state.withLock { current -> Bool in
                guard !current.drained else { return true }
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return true }
                // The durable sink gets the raw bytes before anything is parsed,
                // so a decoding bug can never lose an event.
                stdoutMirror?(chunk)
                for line in current.buffer.append(chunk) { lineContinuation.yield(line) }
                return false
            }
            // Empty means end of file, and the source goes on firing at end of
            // file — half a million times a second, each one now taking the
            // lock. Detach as soon as the descriptor has nothing left to give.
            if spent { handle.readabilityHandler = nil }
        }

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let spent = state.withLock { current -> Bool in
                guard !current.drained else { return true }
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return true }
                current.stderr.append(chunk)
                return false
            }
            if spent { handle.readabilityHandler = nil }
        }

        let terminationRequested = self.terminationRequested
        process.terminationHandler = { process in
            // Detaching stops a new invocation being scheduled; it does not wait
            // for one already running. Closing the door under the lock does: a
            // handler holds it across its whole read-append-yield, so once this
            // returns none is in flight and no later one will read a byte. The
            // descriptors are this handler's alone from here.
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            state.withLock { $0.drained = true }

            // Drained with the lock released. `terminate()` already reaches the
            // child's whole process group — measured directly, an ordinary
            // descendant like fake-claude's looping `sleep` dies in the same
            // instant as the shell — but a descendant that broke into its own
            // session with `setsid()` would not, and would keep the write end
            // open for as long as it lives. `waitForExit` takes this same lock
            // on a cooperative thread, so blocking under it here would park one
            // for exactly that long, on the rare process where it happens.
            let rest = outPipe.fileHandleForReading.readDataToEndOfFile()
            let restErr = errPipe.fileHandleForReading.readDataToEndOfFile()
            if !rest.isEmpty { stdoutMirror?(rest) }

            state.withLock { current in
                for line in current.buffer.append(rest) { lineContinuation.yield(line) }
                current.stderr.append(restErr)

                // A process that ended without a trailing newline still has one
                // last event waiting in the buffer.
                if let tail = current.buffer.flush(), !tail.isEmpty {
                    lineContinuation.yield(tail)
                }
                lineContinuation.finish()
            }

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
    public func terminate(hardKillAfter grace: Duration = ProcessTermination.hardKillGrace) {
        guard process.isRunning else { return }
        terminationRequested.withLock { $0 = true }

        let process = self.process, state = self.state
        ProcessTermination.terminate(process, hardKillAfter: grace) {
            // Both halves, because they close different windows: the state says
            // this object has already published an exit, and `isRunning` covers
            // the stretch between the child being reaped and the termination
            // handler getting as far as publishing — the final drain can sit in
            // the middle of it for as long as a stray descendant holds a pipe.
            state.withLock { $0.exit == nil } && process.isRunning
        }
    }
}
