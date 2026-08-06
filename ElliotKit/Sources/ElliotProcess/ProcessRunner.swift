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
        timeout: Duration? = .seconds(60),
        hardKillAfter: Duration = ProcessTermination.hardKillGrace
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

        let state = Locked(Collected())

        // Both pipes must be drained as the child writes: a child that fills one
        // while we wait on the other deadlocks on the 64 KB pipe buffer.
        //
        // Handlers rather than `readDataToEndOfFile` on a task, because that
        // call blocks the thread it lands on, and `Task.detached` lands on the
        // cooperative pool — the fixed set of threads every `async` function in
        // the process shares.
        //
        // Reading the descriptor and appending what it gave happen under one
        // lock, here and in the final drain below. Nothing else orders the two:
        // a handler preempted between its read and its append interleaves its
        // bytes with the drain's, or appends into a result already returned and
        // loses them. Measured at three empty results in 3840 commands.
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let spent = state.withLock { current -> Bool in
                guard !current.drained else { return true }
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return true }
                current.stdout.append(chunk)
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

        process.terminationHandler = { _ in
            // Detaching stops a new invocation being scheduled; it does not wait
            // for one already running. Closing the door under the lock does: a
            // handler holds it across its whole read-and-append, so once this
            // returns none is in flight and no later one will read a byte.
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            state.withLock { $0.drained = true }

            // Drained with the lock released. A grandchild that inherited the
            // write end holds it open for as long as it likes, and this lock is
            // one an `async` caller takes: blocking under it would park a
            // cooperative thread, which is the whole point of this file.
            let restOut = outPipe.fileHandleForReading.readDataToEndOfFile()
            let restErr = errPipe.fileHandleForReading.readDataToEndOfFile()

            // Publishing the exit and handing off any waiter happen under one
            // lock, so a caller parking at this instant cannot miss it.
            let waiter = state.withLock { current -> CheckedContinuation<Void, Never>? in
                current.stdout.append(restOut)
                current.stderr.append(restErr)
                current.exited = true
                defer { current.waiter = nil }
                return current.waiter
            }
            waiter?.resume()
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

        let timedOut = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await Self.exited(state); return false }
            if let timeout {
                group.addTask {
                    do { try await Task.sleep(for: timeout) } catch { return false }
                    guard process.isRunning else { return false }
                    // SIGTERM, then SIGKILL for a command that ignores it: the
                    // exit is awaited below, so without the second rung a
                    // wedged `gh` would be the very hang this file prevents.
                    // Measured, with the escalation deleted: `swift test` had
                    // no verdict 5 minutes 39 seconds later. The rung and its
                    // grace are `StreamingProcess`'s too — the two spawners
                    // must not disagree about when a child is hopeless.
                    ProcessTermination.terminate(process, hardKillAfter: hardKillAfter) {
                        // Under the lock that publishes the exit, so the kill
                        // cannot land on a pid this run has already reaped and
                        // the kernel has handed to somebody else.
                        state.withLock { !$0.exited } && process.isRunning
                    }
                    return true
                }
            }
            let first = await group.next() ?? false
            // The exit is still awaited on the way out of the group, so a
            // timeout returns only once the terminate has actually landed.
            group.cancelAll()
            return first
        }

        return state.withLock { current in
            ProcessResult(
                exitCode: process.terminationStatus,
                stdoutData: current.stdout,
                stderrData: current.stderr,
                timedOut: timedOut
            )
        }
    }

    /// What the child wrote, and whoever is waiting for it to be complete.
    private struct Collected: @unchecked Sendable {
        var stdout = Data()
        var stderr = Data()
        /// Set once the descriptors belong to the final drain alone. Past this
        /// point a handler still to run must not read a byte.
        var drained = false
        var exited = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    /// Waits for the child, without ever blocking the thread it is called on.
    ///
    /// Deliberately not `waitUntilExit()`: that spins a run loop on whichever
    /// thread it is called from, and a cooperative pool thread is not somewhere
    /// a run loop can live — the runtime is free to park and reuse it, and the
    /// wake-up announcing the child's death then goes nowhere. The call returns
    /// only sometimes, and a verification that never returns leaves the run it
    /// belongs to stuck short of a terminal state for good.
    private static func exited(_ state: Locked<Collected>) async {
        await withCheckedContinuation { continuation in
            // Checking and parking under one lock: the termination handler
            // cannot slip between them and leave this waiting forever.
            let alreadyExited = state.withLock { current -> Bool in
                if current.exited { return true }
                current.waiter = continuation
                return false
            }
            if alreadyExited { continuation.resume() }
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
