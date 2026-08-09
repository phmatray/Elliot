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
    /// `nil` means no ceiling — the behaviour before #57, and the default.
    public var maxBudgetUSD: Double?

    public init(
        runID: UUID,
        prompt: String,
        cwd: String,
        permissionMode: PermissionMode = .bypassPermissions,
        extraAllowedTools: [String] = [],
        includePartialMessages: Bool = false,
        maxBudgetUSD: Double? = nil
    ) {
        self.runID = runID
        self.prompt = prompt
        self.cwd = cwd
        self.permissionMode = permissionMode
        self.extraAllowedTools = extraAllowedTools
        self.includePartialMessages = includePartialMessages
        self.maxBudgetUSD = maxBudgetUSD
    }

    /// Formatted rather than interpolated. `"\(0.5)"` is `"0.5"`, but
    /// `"\(1e-05)"` is `"1e-05"` and `"\(10.0)"` is `"10.0"` — the first would
    /// reach the CLI as scientific notation. Two decimals is money, and the
    /// value is sanitised to be positive and finite before it gets here.
    static func budgetArgument(_ usd: Double) -> String {
        String(format: "%.2f", usd)
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
        // The only bound that can stop a single runaway run: nothing on our side
        // can interrupt a turn in progress. Claude Code ends the run itself and
        // reports `error_max_budget_usd`, which `StreamEventDecoder` already
        // recognises as an error sub-type.
        if let maxBudgetUSD {
            args += ["--max-budget-usd", Self.budgetArgument(maxBudgetUSD)]
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
    /// Output again, after a silence that had already been announced.
    ///
    /// The mirror of `.stalled`, and it exists because the mark was one-way:
    /// this is emitted from the same place the announce latch is cleared, which
    /// used to clear it and tell nobody. Carries no payload — the run's identity
    /// is the stream it arrives on, and *when* it started talking again is the
    /// moment the update is read.
    case resumed
    case finished(ClaudeRunOutcome)
}

extension RunUpdate {
    /// The one place a silence notice becomes an update.
    ///
    /// Both announcing sites — the output mirror and the idle watchdog — go
    /// through this, so the two directions cannot be wired up differently. The
    /// switch is exhaustive with no `default`, so a third direction added to
    /// `RunSilence` is a compile error here rather than a notice that reaches
    /// one site and not the other, which is the shape of the defect this whole
    /// change is about.
    ///
    /// `lastOutput` is honest in both cases: for a stall it is when the silence
    /// began, which is what `.stalled(since:)` has always meant, and for a
    /// recovery it is simply unused.
    static func announcing(_ notice: RunSilence, lastOutput: Date) -> RunUpdate {
        switch notice {
        case .wentQuiet: .stalled(since: lastOutput)
        case .startedTalkingAgain: .resumed
        }
    }
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

    /// How long a run may say nothing before the silence is announced.
    ///
    /// Named, and named *here*, because `RunScheduler` now takes one too: two
    /// literals twenty minutes apart in two modules is a value that drifts, and
    /// this is the one nothing else can be measured against.
    public static let defaultIdleTimeout: Duration = .seconds(20 * 60)

    public static func start(
        invocation: ClaudeInvocation,
        config: ToolConfig,
        logURL: URL,
        idleTimeout: Duration = ClaudeRun.defaultIdleTimeout
    ) throws -> ClaudeRun {
        let arguments = invocation.arguments()

        // The durable sink is a file, not the database: the UI stream is
        // bounded and may drop, this never does.
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        let handleBox = Locked<FileHandle?>(logHandle)

        // One box, not two. The clock reading and the announce latch are a
        // single decision — "is this the byte that ends an announced silence?"
        // cannot be answered by either half alone — and `IdleWatch` is that
        // decision, pure and in `ElliotModel` so a test can drive it.
        let idleWatch = Locked(IdleWatch(lastOutput: Date()))

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
                // Yielded from inside the drain lock, exactly as `LineSink`
                // already yields every line it splits out of this same chunk.
                // It cannot land after the stream is finished: `updates` is
                // finished by the exit task below, which runs only once
                // `waitForExit()` has returned, and the termination handler that
                // publishes that exit holds the drain lock across the final
                // drain — so by then no mirror call is in flight and none is
                // still to come.
                let announcement = idleWatch.withLock { watch -> RunUpdate? in
                    guard let notice = watch.sawOutput(at: Date()) else { return nil }
                    return .announcing(notice, lastOutput: watch.lastOutput)
                }
                if let announcement { updateContinuation.yield(announcement) }
            }
        )

        updateContinuation.yield(.started(pid: process.processIdentifier))

        // Decode lines into events. `decodeAll`, never `decode`: one NDJSON line
        // can carry an assistant turn with prose *and* one or more tool calls in
        // the same `message.content` array, and `decode` is `decodeAll(…).first`
        // — it returns the prose and drops every tool call that shared the turn
        // with it.
        //
        // A line is one-to-many here, not one-to-one, and that is the whole
        // point: the file on disk is read back through `decodeAll` already, so
        // while this said `decode` the same run read differently depending on
        // when you opened it — the live tail short of its tool calls, the log
        // complete. Nothing failed; the two just disagreed.
        let decodeTask = Task {
            for await line in process.lines {
                for event in StreamEventDecoder.decodeAll(line: line) {
                    updateContinuation.yield(.event(event))
                }
            }
        }

        // Watch for silence. There is deliberately no wall-clock kill: waiting
        // hours on CI is legitimate for merge-pr. Silence is the useful signal.
        let idleTask = Task {
            // Polls at the window rather than at a flat thirty seconds. `min`
            // leaves the shipped twenty-minute window polling exactly as it did,
            // and stops a shorter one — the only way a test reaches this loop at
            // all — being announced up to thirty seconds after it was crossed.
            let interval = min(idleTimeout, .seconds(30))
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { break }
                let announcement = idleWatch.withLock { watch -> RunUpdate? in
                    guard let notice = watch.tick(now: Date(), idleTimeout: idleTimeout)
                    else { return nil }
                    return .announcing(notice, lastOutput: watch.lastOutput)
                }
                if let announcement { updateContinuation.yield(announcement) }
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
    ///
    /// `decode` and not `decodeAll` here, and that is not the oversight the live
    /// path above was: a `"result"` line decodes to exactly one event, so the
    /// first *is* all of them. This asks a line one yes-or-no question, where
    /// the tail has to render every block of it.
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
