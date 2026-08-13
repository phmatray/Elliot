import ACP
import Foundation

/// ACP over a child's stdio, on top of `ChildProcess`.
///
/// The vendored library shipped its own `StdioTransport` and `ProcessManager`, both of which
/// constructed a `Process`. Deleting them and writing this is the whole point: `ChildProcess` owns
/// the spawn, the two-pipe drain, the exit publication and the SIGTERM→SIGKILL escalation, and
/// there is exactly one of it. What remains here is this transport's own idea — that stdout is a
/// sequence of newline-delimited JSON messages, and that stdin is writable.
///
/// Modelled on `StreamingProcess`, which is the same shape one protocol lower.
public final class ACPTransport: Transport, Sendable {
    private let child: ChildProcess<MessageSink>

    /// Splits chunks into messages. Called under `ChildProcess`'s lock — which is what stops a
    /// handler caught mid-flight by the child's exit yielding into a stream the final drain has
    /// already finished.
    private struct MessageSink: ChildOutputSink {
        var buffer = LineBuffer()
        var stderr = Data()
        let continuation: AsyncStream<Data>.Continuation

        mutating func receiveStdout(_ chunk: Data) {
            for line in buffer.append(chunk) where !line.isEmpty {
                continuation.yield(line)
            }
        }

        mutating func receiveStderr(_ chunk: Data) { stderr.append(chunk) }

        mutating func finish() {
            if let tail = buffer.flush(), !tail.isEmpty { continuation.yield(tail) }
            continuation.finish()
        }
    }

    /// Complete JSON-RPC messages, in order. Finishes when the agent exits.
    ///
    /// Unbounded, like `StreamingProcess.lines` and unlike the UI's run stream: dropping a
    /// JSON-RPC response is not a degraded picture, it is a request that never returns.
    public let messages: AsyncStream<Data>

    /// Serializes every write to the child's stdin — and its close — off the cooperative thread
    /// pool.
    ///
    /// `ChildProcess.writeStdin` is synchronous and blocks when the pipe buffer is full and the
    /// child is not reading — exactly the kind of call `async` code must never make directly, since
    /// the thread it runs on belongs to the fixed cooperative pool every `async` function in the
    /// process shares (the same reasoning `ChildProcess.wait()`'s doc comment gives for not calling
    /// `waitUntilExit()`, and the defect `3b1c226`/#18 is a receipt for on the read side). `send`
    /// therefore hops onto this queue and lets the block happen there instead.
    ///
    /// It must be *serial*, not merely off-thread: two concurrent JSON-RPC writes racing each other
    /// onto the same stdin could interleave their bytes mid-line, corrupting both messages.
    /// `writeStdin` already serializes under its own lock, but that only protects one call at a
    /// time — a serial queue is what keeps a second `async` caller from starting its write before
    /// the first one's continuation has resumed. Do not replace this with `DispatchQueue.global()`
    /// or a `Task.detached {}` — either reintroduces the race this queue exists to close.
    ///
    /// `close()` shares this queue rather than calling `closeStdin()` directly. `closeStdin()`
    /// takes the same lock a blocking `writeStdin` holds across its write, so calling it from the
    /// caller's own thread could park a cooperative-pool thread exactly like an unbridged `send`
    /// would — a review round on this file caught that once already. Sharing the queue also makes
    /// `close()` FIFO behind any `send` already enqueued, so a pending write is never silently
    /// pre-empted by a close arriving on a different task.
    private let stdinQueue = DispatchQueue(label: "dev.phmatray.elliot.acp-transport.stdin")

    public init(_ agent: ACPAgentProcess) throws {
        var continuation: AsyncStream<Data>.Continuation!
        messages = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }

        child = try ChildProcess(
            executable: agent.executable,
            arguments: agent.arguments,
            cwd: agent.cwd,
            environment: agent.environment,
            stdin: .pipe,
            sink: MessageSink(continuation: continuation!)
        )
    }

    /// Sends one JSON-RPC message, framed with the newline the protocol delimits on.
    public func send(_ data: Data) async throws {
        var framed = data
        framed.append(0x0A)
        try await writeOnStdinQueue(framed)
    }

    /// Sends bytes verbatim, framing included. For tests that need to write half a line.
    func sendRaw(_ data: Data) async throws {
        try await writeOnStdinQueue(data)
    }

    /// Bridges the blocking `writeStdin` call onto `stdinQueue`, so the calling `async` context
    /// never parks a cooperative thread waiting on the child to read its pipe.
    private func writeOnStdinQueue(_ data: Data) async throws {
        let child = self.child
        try await onStdinQueue { try child.writeStdin(data) }
    }

    /// Runs `work` on `stdinQueue` and resumes once it returns, so every caller of this queue —
    /// `send`, `sendRaw`, `close` — goes through one dispatch-then-resume shape rather than each
    /// reimplementing it. That is as much the point as the queue itself: two structurally identical
    /// `withCheckedContinuation` blocks in this file would be the same kind of duplication this
    /// package's own `DrainDuplicationTests` exists to catch one layer down, in `ChildProcess`.
    private func onStdinQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            stdinQueue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Closes stdin and lets the agent exit on its own terms.
    ///
    /// ⛔ Not `terminate()`. A well-behaved agent exits when its stdin closes, having flushed
    /// whatever it still owed; signalling it first would race that flush.
    ///
    /// Routed through `stdinQueue` rather than calling `child.closeStdin()` on the caller's own
    /// thread — see the queue's own doc comment for why that mattered. `closeStdin()` itself cannot
    /// throw, so `onStdinQueue`'s error path is unreachable here; `try?` only satisfies the type
    /// system, it never actually discards a failure.
    public func close() async {
        let child = self.child
        try? await onStdinQueue { child.closeStdin() }
    }

    public var isConnected: Bool {
        get async { child.isRunning }
    }

    public var processIdentifier: Int32 { child.processIdentifier }

    /// Asks the agent to stop, escalating only if it ignores the request. The backstop for an
    /// agent that does not exit when its stdin closes.
    public func terminate(hardKillAfter grace: Duration = ProcessTermination.hardKillGrace) {
        child.terminate(hardKillAfter: grace)
    }

    public func waitForExit() async -> Int32 {
        await child.wait().code
    }

    /// The child's stderr, accumulated across its whole lifetime under the drain lock — the same
    /// mechanism `StreamingProcess.waitForExit` reads its own `Exit.stderr` through.
    ///
    /// This is where an adapter's crash reason lands: a failed `npx` resolution, a Node stack
    /// trace, a missing `CLAUDE_CODE_EXECUTABLE`. Collecting it into `MessageSink.stderr` without
    /// exposing it would pay the cost of holding every byte for the whole session and buy the
    /// caller nothing back — so a caller that sees a nonzero `waitForExit()` should read this
    /// before deciding the run failed silently.
    ///
    /// ⚠️ Unlike `LineBuffer`, which caps a runaway line at 32 MB, nothing bounds this — a
    /// pathological agent that writes gigabytes to stderr grows it without limit. Recorded as
    /// deferred by the branch review, not fixed in this pass.
    public func collectedStderr() -> String {
        child.withSink { String(decoding: $0.stderr, as: UTF8.self) }
    }
}
