import ElliotModel
import Foundation

/// The run log's two Elliot-authored line shapes, and the single writer that keeps them from
/// interleaving with the adapter's own bytes.
///
/// A run log is one JSON object per line — decision 5 — and everything downstream rests on it:
/// Task 17's first-line discriminator tells a stream-json log from an ACP one by reading the first
/// line, and `AgentLog`'s own backwards scan (Task 9) asks each line one yes-or-no question.
public enum AgentLog {
    /// ⛔ **A method the adapter can never send. That is what lets a backwards scan trust what it
    /// finds, and what stops a future adapter notification being mistaken for Elliot's own
    /// record.** Every method the protocol defines is `session/…`, `nes/…`, `document/…`,
    /// `providers/…`, `mcp/…`, `initialize`, `authenticate` or `logout`; nothing in it is
    /// namespaced `elliot/`, and nothing ever will be.
    public static let sessionMethod = "elliot/session"
    public static let terminalMethod = "elliot/terminal"

    /// What the handshake established, as a line the log can carry.
    ///
    /// A JSON-RPC **notification** rather than a bare object, so the file stays uniform: every
    /// line in a run log — the adapter's and Elliot's alike — is a JSON-RPC message.
    public static func sessionLine(_ info: RunSessionInfo) -> Data {
        line(method: sessionMethod, params: info)
    }

    /// What the turn amounted to.
    ///
    /// ⛔ Elliot writes this itself, and that is not a convenience. Under `claude -p` the terminal
    /// `result` was a stream-json line like any other, so the log was self-sufficient for free.
    /// Under ACP the `stopReason` comes back as the **response** to `session/prompt` — never a
    /// notification, so it never reaches the log unless we put it there.
    public static func terminalLine(_ summary: TurnSummary) -> Data {
        line(method: terminalMethod, params: summary)
    }

    private struct Line<Params: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let method: String
        let params: Params
    }

    /// ⚠️ Non-throwing, and the fallback is unreachable by construction rather than by hope.
    /// `RunSessionInfo` and `TurnSummary` are `String`/`Int`/`Bool`/array/`Double?` all the way
    /// down, and the only way `JSONEncoder` can fail on that shape is a non-finite `Double` — the
    /// single candidate being `RunUsage.costUSD`, which arrives through `JSONDecoder` off the
    /// wire, and `JSONDecoder` rejects `nan`/`inf` before it ever gets here. The fallback exists
    /// anyway because the alternative is a `try!` in the one place whose whole job is that the log
    /// stays parseable: a `params: null` line is still one JSON object, so decision 5 survives
    /// even in the case that cannot happen.
    private static func line(method: String, params: some Encodable) -> Data {
        guard let encoded = try? JSONEncoder().encode(Line(method: method, params: params)) else {
            return Data(#"{"jsonrpc":"2.0","method":"\#(method)","params":null}"#.utf8)
        }
        return encoded
    }

    /// The run log's single writer: the raw stdout mirror **and** Elliot's own records, under one
    /// lock, keeping a pending partial line so the two can never interleave mid-frame.
    ///
    /// ⛔ **Why a writer rather than a `Locked<FileHandle?>`.** `ClaudeRun` had exactly one writer
    /// — the mirror, under the drain lock — so a bare handle box was enough. This log has three:
    /// the mirror writes raw *chunks*, and Elliot writes whole *lines* into the same file. A chunk
    /// boundary has no relationship to a line boundary (`LineBuffer`'s own header says so), so a
    /// chunk can end halfway through a JSON-RPC frame; if `elliot/session` or `elliot/terminal`
    /// were written at that moment, the file would get two unparseable lines and decision 5's
    /// "one JSON object per line" would quietly stop being true. That is not hypothetical timing:
    /// `elliot/session` is written the instant `session/new` returns, while the adapter is
    /// streaming `available_commands_update`.
    ///
    /// `mirror` therefore writes only up to and including the **last newline in the chunk** and
    /// keeps the remainder, so the file always ends on a boundary while the writer is open, and
    /// `record` cannot land inside a frame. The held partial frame is written intact later, when
    /// its own newline arrives.
    ///
    /// ⚠️ The one thing this changes about the file is ordering: a partial adapter frame that was
    /// in flight appears **after** an Elliot record rather than around it. Nothing is dropped and
    /// every line is whole; the sequence is simply not the order the bytes arrived in.
    ///
    /// ⚠️ `close()` flushes whatever tail is left **without** appending a newline. A child that
    /// ended mid-line really did end mid-line, and inventing the boundary would turn a truncated
    /// frame into a plausible-looking one. Nothing writes after `close()`, so the invariant it
    /// gives up is not one anybody still needs.
    final class Writer: Sendable {
        private struct State {
            var handle: FileHandle?
            var pending = Data()
        }

        private let state: Locked<State>

        init(_ handle: FileHandle) {
            state = Locked(State(handle: handle))
        }

        /// Called under `ChildProcess`'s drain lock. Everything it does is synchronous and under
        /// this writer's own lock, which is the point — see the type's doc comment.
        func mirror(_ chunk: Data) {
            state.withLock { state in
                guard let handle = state.handle else { return }
                state.pending.append(chunk)
                guard let newline = state.pending.lastIndex(of: 0x0A) else { return }
                let boundary = state.pending.index(after: newline)
                let whole = Data(state.pending[state.pending.startIndex..<boundary])
                state.pending = Data(state.pending[boundary...])
                try? handle.write(contentsOf: whole)
            }
        }

        /// Writes one of Elliot's own lines, framed with the newline the log delimits on.
        func record(_ line: Data) {
            state.withLock { state in
                guard let handle = state.handle else { return }
                var framed = line
                framed.append(0x0A)
                try? handle.write(contentsOf: framed)
            }
        }

        /// Flushes the held tail, then closes. Idempotent.
        func close() {
            state.withLock { state in
                if !state.pending.isEmpty {
                    try? state.handle?.write(contentsOf: state.pending)
                    state.pending = Data()
                }
                try? state.handle?.close()
                state.handle = nil
            }
        }
    }
}
