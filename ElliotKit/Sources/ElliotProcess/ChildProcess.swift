import Foundation

/// Receives a child's output. **Every method is called with the drain lock
/// held** — that is the point of the type, not an implementation detail.
///
/// The seam is "called under the lock" rather than "here are the bytes, deal
/// with them" because *under the lock* is the entire invariant. A sink handed a
/// chunk to process later is a sink that can append to a result already
/// returned, or yield into a stream already finished — which is the defect this
/// exists to make unexpressible rather than to warn about.
///
/// The cost is real and is the caller's to weigh: whatever a sink does, the
/// drain is not running while it does it. `LineSink` writes to the run's log
/// under this lock, which is why `ChildProcess` never consults it from the
/// SIGKILL backstop.
protocol ChildOutputSink: Sendable {
    mutating func receiveStdout(_ chunk: Data)
    mutating func receiveStderr(_ chunk: Data)
    /// Called once, from the final drain, after the last chunk. The last chance
    /// to flush a partial line or finish a stream — still under the lock.
    mutating func finish()
}

/// How a child ended.
struct ChildTermination: Sendable {
    var code: Int32
    /// Set when `terminate()` was asked for rather than the child ending on its
    /// own. No exit status carries this, which is why it is recorded here.
    var wasTerminated: Bool
}

/// Spawns a child, drains both its pipes under one lock, and publishes its exit.
///
/// This mechanism was written twice — once in `ProcessRunner`, once in
/// `StreamingProcess` — and the copy was not incidental: eight comment lines
/// were byte-identical between the two files, and they were the load-bearing
/// arguments themselves. Three defects were fixed in one file at a time
/// (`22bb230` the dropped run tails, `3b1c226`/#18 the parked cooperative
/// thread, `36b6da6`/#105 the missing SIGKILL rung), and a fourth investigation
/// (#26) would have landed in one file had it reproduced. The comments below
/// are those receipts, moved here rather than rewritten; each now describes one
/// implementation instead of one of two.
///
/// The only seam is `Sink`. `ProcessRunner` supplies one that appends to two
/// `Data` buffers; `StreamingProcess` supplies one that mirrors raw bytes to the
/// log, feeds a `LineBuffer` and yields lines. Neither touches a `Pipe`, a
/// `readabilityHandler` or a `CheckedContinuation` again.
final class ChildProcess<Sink: ChildOutputSink>: Sendable {
    private let process: Process
    private let state: Locked<Drain>
    private let terminationRequested = Locked(false)

    /// What the sink has accumulated, and whoever is waiting for it to be
    /// complete.
    ///
    /// `@unchecked` for the continuation, which is not `Sendable`; every access
    /// to it is under the mutex, which is what makes that safe.
    private struct Drain: @unchecked Sendable {
        var sink: Sink
        /// Set once the descriptors belong to the final drain alone. Past this
        /// point a handler still to run must not read a byte.
        var drained = false
        /// Doubles as the exited flag. A separate `Bool` would be a second
        /// record of the same fact, and the two could disagree.
        var termination: ChildTermination?
        /// Whoever is waiting for the exit, parked under the same lock that
        /// publishes it.
        var waiter: CheckedContinuation<ChildTermination, Never>?
    }

    /// What the child's stdin is connected to.
    ///
    /// `.null` is the default and stays the default: a child that inherits the app's stdin blocks
    /// waiting on it, which is what the single line here always prevented.
    ///
    /// `.pipe` exists for one kind of caller — an agent spoken to over JSON-RPC, which is written
    /// to rather than only read from. ⛔ Its writer never closes the handle: a helper whose stdin
    /// closes exits having written nothing, which reads exactly like a helper that failed to start.
    /// Only `closeStdin()` closes it, and only at teardown.
    enum StandardInput: Sendable {
        case null
        case pipe
    }

    /// Tri-state rather than `FileHandle?`, which cannot distinguish "never piped" from "piped,
    /// then closed" — the same two-valued answer to a three-valued question this project has
    /// already paid for once, in `PreflightState.notChecked`. `writeStdin` answers each state on
    /// its own, so its error never describes a state the caller has already left.
    private enum StdinState: Sendable {
        case notPiped
        case open(FileHandle)
        case closed
    }

    /// Boxed because the write, the close and the drain can each land on a different isolation.
    private let stdinState: Locked<StdinState>

    init(
        executable: String,
        arguments: [String],
        cwd: String?,
        environment: [String: String],
        stdin: StandardInput = .null,
        sink: Sink
    ) throws {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ProcessError.notExecutable(executable)
        }

        process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        switch stdin {
        case .null:
            // Never let a child inherit the app's stdin and block waiting on it.
            process.standardInput = FileHandle.nullDevice
            stdinState = Locked(.notPiped)
        case .pipe:
            let inPipe = Pipe()
            process.standardInput = inPipe

            // Measured 2026-08-12 (Task 4, `SIGPIPEMeasurementTests`): writing to this pipe's
            // write end after the child has already exited and closed its read end raises
            // SIGPIPE, whose default disposition **terminates the process** — reproduced 3/3
            // runs (signal 13), with no thrown error and no failing test: the whole `swift test`
            // process simply went away mid-test. `ACPTransport.send` calls `writeStdin` from an
            // `async` context that has no way to know the agent it is talking to exited moments
            // earlier, so "the child is already gone" is an ordinary race here, not an edge case.
            //
            // `F_SETNOSIGPIPE` disables that **for this one file descriptor**, never process-wide:
            // a write past a closed reader on it now returns -1/EPIPE instead of raising the
            // signal. Deliberately not `signal(SIGPIPE, SIG_IGN)`, which is process-global and not
            // a library's to set — it would silently change every other write in the app, not just
            // this pipe.
            let writeHandle = inPipe.fileHandleForWriting
            guard fcntl(writeHandle.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
                // A pipe that can still kill the process on write is not a child worth having.
                // Failing loudly here, rather than swallowing a nonzero return, is the whole
                // point — a silently-failed fcntl would hand back exactly the fatal behaviour
                // this guard exists to remove, with nothing pointing at why.
                throw ProcessError.stdinSigPipeGuardFailed(errno)
            }
            stdinState = Locked(.open(writeHandle))
        }

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        state = Locked(Drain(sink: sink))
        let state = self.state

        // Both pipes must be drained as the child writes: a child that fills one
        // while we wait on the other deadlocks on the 64 KB pipe buffer.
        //
        // Handlers rather than `readDataToEndOfFile` on a task, because that
        // call blocks the thread it lands on, and `Task.detached` lands on the
        // cooperative pool — the fixed set of threads every `async` function in
        // the process shares.
        //
        // Reading the descriptor and handing what it gave to the sink happen
        // under one lock, here and in the final drain below. Nothing else orders
        // the two: a handler preempted between its read and its hand-off
        // interleaves its bytes with the drain's, or appends into a result
        // already returned and loses them. Measured at three empty results in
        // 3840 commands — and, in the streaming case, at an entire run arriving
        // empty because a handler caught mid-flight yielded its lines after the
        // drain had finished the stream.
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let spent = state.withLock { current -> Bool in
                guard !current.drained else { return true }
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return true }
                current.sink.receiveStdout(chunk)
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
                current.sink.receiveStderr(chunk)
                return false
            }
            if spent { handle.readabilityHandler = nil }
        }

        let terminationRequested = self.terminationRequested
        process.terminationHandler = { process in
            // Detaching stops a new invocation being scheduled; it does not wait
            // for one already running. Closing the door under the lock does: a
            // handler holds it across its whole read-and-hand-off, so once this
            // returns none is in flight and no later one will read a byte. The
            // descriptors are this handler's alone from here.
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            state.withLock { $0.drained = true }

            // Drained with the lock released. A grandchild that inherited the
            // write end holds it open for as long as it likes — `terminate()`
            // already reaches the child's whole process group, measured
            // directly, but a descendant that broke into its own session with
            // `setsid()` would not. This lock is one an `async` caller takes,
            // and a sink may hold it across a write to the run's log, so
            // blocking under it would park a cooperative thread for exactly
            // that long.
            let restOut = outPipe.fileHandleForReading.readDataToEndOfFile()
            let restErr = errPipe.fileHandleForReading.readDataToEndOfFile()

            let termination = ChildTermination(
                code: process.terminationStatus,
                wasTerminated: terminationRequested.withLock { $0 }
            )

            // The last bytes, the sink's close-out, the exit and the waiter
            // hand-off all under one lock, so a caller parking at this instant
            // cannot miss it and hang forever. `finish()` is inside it for the
            // same reason the yields are: a stream finished with the lock
            // released is a stream a late handler can still yield into.
            let waiter = state.withLock { current -> CheckedContinuation<ChildTermination, Never>? in
                if !restOut.isEmpty { current.sink.receiveStdout(restOut) }
                if !restErr.isEmpty { current.sink.receiveStderr(restErr) }
                current.sink.finish()
                current.termination = termination
                defer { current.waiter = nil }
                return current.waiter
            }
            waiter?.resume(returning: termination)
        }

        do {
            try process.run()
        } catch {
            // A spawn that never happened has no termination handler to detach
            // these, and a handler keeps its own handle alive: leaving them on
            // would leak two descriptors per failure.
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
    }

    var isRunning: Bool { process.isRunning }
    var processIdentifier: Int32 { process.processIdentifier }

    /// Waits for the child to exit, without ever blocking the thread it is
    /// called on.
    ///
    /// Deliberately not `waitUntilExit()`: that spins a run loop on whichever
    /// thread it is called from, and a cooperative pool thread is not somewhere
    /// a run loop can live — the runtime is free to park and reuse it, and the
    /// wake-up announcing the child's death then goes nowhere. The call returns
    /// only sometimes, and a verification that never returns leaves the run it
    /// belongs to stuck short of a terminal state for good.
    func wait() async -> ChildTermination {
        await withCheckedContinuation { continuation in
            // Checking and parking under one lock: the termination handler
            // cannot slip between them and leave this waiting forever.
            let alreadyExited = state.withLock { current -> ChildTermination? in
                if let termination = current.termination { return termination }
                current.waiter = continuation
                return nil
            }
            if let alreadyExited { continuation.resume(returning: alreadyExited) }
        }
    }

    /// Reads whatever the sink has accumulated, under the lock.
    ///
    /// Copies the sink out rather than lending a reference, so nothing a caller
    /// does with it can run inside the drain.
    func withSink<T: Sendable>(_ body: (Sink) -> T) -> T {
        state.withLock { body($0.sink) }
    }

    /// Writes to the child's stdin.
    ///
    /// Synchronous and under a lock, so two callers cannot interleave halves of a JSON-RPC line.
    /// A write blocks if the child is not reading; the messages this carries are single lines, and
    /// an agent that has stopped reading is one `terminate()` is about to reach anyway.
    ///
    /// ⛔ Never call this from a `ChildOutputSink` method. Those run with the drain lock held, and a
    /// blocking write from inside one can deadlock: the write waits for the child to read its stdin,
    /// the child is blocked writing to its own full stdout pipe, and stdout only drains through the
    /// sink method that is now stuck making this call. Nothing inverts a lock — the same lock simply
    /// never lets go.
    func writeStdin(_ data: Data) throws {
        try stdinState.withLock { state in
            switch state {
            case .open(let handle):
                try handle.write(contentsOf: data)
            case .notPiped:
                throw ProcessError.stdinNotPiped
            case .closed:
                throw ProcessError.stdinClosed
            }
        }
    }

    /// Closes the child's stdin, which is how a well-behaved agent learns to exit.
    ///
    /// Separate from `terminate()` on purpose: closing is a request the child may take its time
    /// over, and `terminate()` is the escalation. Safe to call twice, and a no-op on a child that
    /// was never piped.
    func closeStdin() {
        stdinState.withLock { state in
            guard case .open(let handle) = state else { return }
            try? handle.close()
            state = .closed
        }
    }

    /// Asks the child to stop, escalating only if it ignores the request.
    ///
    /// SIGTERM first because Claude Code shuts itself down cleanly on it;
    /// SIGKILL is the backstop for a process that is wedged.
    func terminate(hardKillAfter grace: Duration = ProcessTermination.hardKillGrace) {
        guard process.isRunning else { return }
        terminationRequested.withLock { $0 = true }

        let process = self.process
        ProcessTermination.terminate(process, hardKillAfter: grace) {
            // Deliberately `isRunning` alone, and deliberately not the drain
            // lock. A sink may hold that lock across a synchronous write to the
            // run's log file, so reading it here would let a slow — or wedged —
            // disk delay the one signal that is supposed to be unconditional. A
            // backstop that can block on the log it is trying to close out is
            // not a backstop.
            //
            // Nothing is lost by it, and this is the one place where unifying
            // the two spawners changed behaviour rather than moving lines:
            // `ProcessRunner` used to add `state.withLock { !$0.exited } &&` in
            // front of this. That flag is set inside the termination handler,
            // which only runs once Foundation has already reaped the child, so
            // `isRunning` has gone false strictly earlier — the extra term could
            // never have vetoed a kill this one allows. Its own comment conceded
            // as much, calling it "belt and braces, not a guarantee", since the
            // lock is released before the signal either way.
            process.isRunning
        }
    }
}
