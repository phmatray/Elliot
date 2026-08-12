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

    /// Serializes every write to the child's stdin off the cooperative thread pool.
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
    /// the first one's `withCheckedContinuation` has resumed. Do not replace this with
    /// `DispatchQueue.global()` or a `Task.detached {}` — either reintroduces the race this queue
    /// exists to close.
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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            stdinQueue.async {
                do {
                    try child.writeStdin(data)
                    continuation.resume()
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
    public func close() async {
        child.closeStdin()
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
}
