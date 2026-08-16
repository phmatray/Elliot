import ACPModel
import ElliotModel
import Foundation

/// The run log's three Elliot-authored line shapes, and the single writer that keeps them from
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
    public static let refusalsMethod = "elliot/refusals"

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

    /// What this run's `PermissionPolicy` refused, as a line the log can carry.
    ///
    /// ⛔ **Written only when the list is non-empty, and that is the point rather than tidiness.**
    /// Every skill run spawns at `bypassPermissions`, where the design says no
    /// `session/request_permission` should arrive at all — and measured, none does. A line here is
    /// therefore evidence that #585 reproduced, not a routine record; a `"toolNames": []` written
    /// on every clean turn would bury the one turn that mattered among thousands that did not.
    ///
    /// ⚠️ **Deliberately not `TurnSummary.denials`, and not foldable into it.** That list comes
    /// from `nonExecutionKind` — the *agent's* account of a tool call that did not run. This is
    /// *Elliot's* account of a request it refused, and the two are independent records that can
    /// disagree: whether the adapter mirrors a client-side rejection back into a `tool_call` frame
    /// is unmeasured, so on an adapter that does not, this line is the only place the refusal is
    /// named at all.
    public static func refusalsLine(_ toolNames: [String]) -> Data {
        line(method: refusalsMethod, params: Refusals(toolNames: toolNames))
    }

    /// An object rather than a bare `[String]`, so this line has the same shape as the other two —
    /// a named field can gain a sibling later; a top-level array cannot without changing type.
    private struct Refusals: Encodable {
        let toolNames: [String]
    }

    private struct Line<Params: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let method: String
        let params: Params
    }

    /// What the turn amounted to, recovered from the log rather than from memory.
    ///
    /// `ClaudeRun.lastResult(inLogAt:)` is the shape this is modelled on, and its two reasons carry
    /// over unchanged. **Backwards**, because the terminal line is the last thing a finished run
    /// wrote and a log can be long. **One yes-or-no question per line**, because a scan does not
    /// need to render a log to find one line in it — the fold that builds rows is
    /// `RunLog.rows(from:denials:summary:)`, and it is a different job.
    ///
    /// ⛔ Elliot writes this line itself, and that is not a convenience. Under `claude -p` the
    /// terminal `result` was a stream-json line like any other, so the log was self-sufficient for
    /// free. Under ACP the `stopReason` comes back as the **response** to `session/prompt` — it is
    /// never a notification, so it never reaches the log unless we put it there. `Reconciler` does
    /// not read the log at all: its launch sweep hardcodes `.failed` for a run that died with the
    /// app (`Reconciler.swift:41-58`), because a run that never came back produced no outcome to
    /// read.
    ///
    /// ⚠️ **Nothing in production calls this yet, and the sentence that stood here claimed
    /// otherwise.** It said `RunScheduler.finish` reads what this scan finds on every run — true of
    /// `ClaudeRun`, which really does recover its outcome from the log
    /// (`ClaudeRunner.swift:301-310`), and not true of `AgentRun`, which hands
    /// `AgentRunOutcome.summary` straight from the value it assembled and wrote
    /// (`ACPRunner.swift:516-525`). That difference is deliberate rather than an omission: under
    /// `claude -p` the log carried the agent's **own** bytes, so it was the source; here it carries
    /// Elliot's transcription of a response it already holds, so reading the transcription back
    /// would let a failed write report itself as a fact about the agent — *this run died mid-turn*
    /// — which is this repository's most expensive recurring mistake, a measurement taken against a
    /// rendering. The two are pinned to agree instead:
    /// `AgentLogTests.theTerminalLineIsNotLostToTheExit` asserts the whole value the caller was
    /// handed equals the whole value the file kept, so a transcription that stopped round-tripping
    /// would fail rather than diverge in silence.
    ///
    /// The readers this exists for are the ones with no memory to consult: the archive render —
    /// `RunLog.rows(from:denials:summary:)` takes exactly the `summary` this returns — and any
    /// session that did not run the turn. Until one of them lands, this function is guarded only by
    /// its own tests.
    ///
    /// ⚠️ **`nil` is three different facts and this signature cannot tell them apart.** The plan
    /// fixes the return type, so the honest thing is to name them rather than let one absence read
    /// as one cause. `nil` means: no `elliot/terminal` line was ever written — the run died
    /// mid-turn, the fact this whole design exists to preserve; **or** the log could not be read at
    /// all; **or** the line is there and this build cannot decode its params, which
    /// `TurnSummary`'s own doc comment describes as a live consequence of adding a field without
    /// `Optional` or `@DefaultsToEmpty`, and which
    /// `AgentLogTests.anUndecodableRecordIsIndistinguishableFromNone` measures. A caller must
    /// therefore not read `nil` as "the run died mid-turn" on this evidence alone — pair it with
    /// the exit code, which `AgentRunOutcome` carries for that reason.
    public static func lastSummary(inLogAt url: URL) -> TurnSummary? {
        last(TurnSummary.self, method: terminalMethod, inLogAt: url)
    }

    /// What the handshake established, recovered the same way.
    ///
    /// ⚠️ The plan calls this `SessionInfo`; the model type is `RunSessionInfo`, and its own doc
    /// comment says why it is not the shorter name — `ACPModel.SessionInfo` already exists in this
    /// module's dependencies and means a different thing (a session-**listing** entry).
    ///
    /// Backwards like its sibling, though the session line is the log's *first* method-bearing
    /// record and a forward scan would find the same one: a run opens exactly one session, so
    /// direction cannot change the answer, and sharing the scan is worth more than matching the
    /// direction to the intuition. Where they would differ — a log that somehow carried two — the
    /// **last** is the right reading anyway, since it is the one the run ended under.
    public static func sessionInfo(inLogAt url: URL) -> RunSessionInfo? {
        last(RunSessionInfo.self, method: sessionMethod, inLogAt: url)
    }

    /// The whole run, replayed from the file, for a reader that was not there when it happened.
    ///
    /// The archive's half of the live consumer in `ACPRunner` (`ACPRunner.swift:827-861`), and
    /// deliberately its *same two statements*: encode the notification's params, decode them as a
    /// `SessionUpdateNotification`, hand them to `RunEventMapper`. A second decode path would be a
    /// second way to read the same bytes, and the panel would draw a finished run differently from
    /// the one it had just watched.
    ///
    /// Three line kinds and only three:
    ///
    /// - `elliot/session` becomes `.session`, which is what the live path yields directly from the
    ///   handshake rather than from a frame;
    /// - `session/update` goes through the mapper, with the same `catch` yielding `.unreadable`
    ///   rather than dropping a line this build cannot understand;
    /// - everything else is skipped. Half the lines in a run log are **responses** — `id` and
    ///   `result`, no `method` at all — and `JSONRPCNotification` refuses them for that reason, so
    ///   `initialize` cannot fold into a row.
    ///
    /// ⚠️ **`elliot/terminal` is skipped here, and that is not an omission.** The turn's summary
    /// is not an event: `RunLog.rows(from:denials:summary:)` takes it as its own argument, because
    /// the stop reason arrives as the `session/prompt` **response** and there is no frame in the
    /// stream that carries it. `lastSummary(inLogAt:)` above is how a caller gets it, and a
    /// caller wanting the archive's rows needs both calls.
    ///
    /// ⚠️ `elliot/refusals` is skipped too. It is *Elliot's* account of a request it refused,
    /// while the rows' denial list is the *agent's* account read off `nonExecutionKind` — the two
    /// are independent records that `refusalsLine`'s own comment says can disagree, and folding
    /// one into the other here would silently make them one.
    public static func events(inLogAt url: URL) -> [RunEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        var events: [RunEvent] = []
        for line in data.split(separator: 0x0A) {
            // Re-based for `JSONDecoder`, exactly as `last(_:method:inLogAt:)` above does.
            let line = Data(line)
            guard let notification = try? decoder.decode(JSONRPCNotification.self, from: line)
            else { continue }
            switch notification.method {
            case sessionMethod:
                guard let record = try? decoder.decode(Record<RunSessionInfo>.self, from: line)
                else { continue }
                events.append(.session(record.params))
            case "session/update":
                let raw = (try? encoder.encode(notification.params)) ?? Data()
                do {
                    let note = try decoder.decode(SessionUpdateNotification.self, from: raw)
                    events.append(contentsOf: RunEventMapper.events(from: note))
                } catch {
                    events.append(.unreadable(raw: raw, error: String(describing: error)))
                }
            default:
                continue
            }
        }
        return events
    }

    /// Just enough of a line to answer "is this one of ours, and which".
    ///
    /// ⛔ **Asked first, and separately, because the namespace is the whole guarantee.** Decoding
    /// the params and inferring the kind from whether they fit would let an adapter frame carrying
    /// a `stopReason` be read as Elliot's own record — the exact confusion `terminalMethod`'s
    /// `elliot/` prefix exists to make impossible. `method` is `Optional` because a *response* line
    /// carries `id` and no `method` at all, and half the lines in a run log are responses.
    private struct Envelope: Decodable {
        let method: String?
    }

    private struct Record<Params: Decodable>: Decodable {
        let params: Params
    }

    /// The one scan, so `lastSummary` and `sessionInfo` cannot drift apart.
    ///
    /// ⚠️ A line that names the right method and whose params will not decode is **skipped**, and
    /// the reason first written here was wrong. It said the skip "leaves the scan looking rather
    /// than assert that the run never ended" — but a run writes exactly one `elliot/session` and
    /// exactly one `elliot/terminal` (`ACPRunner.swift:416` and `:523`), so on every log this
    /// package produces there is nothing further to look at, and skipping the only record there is
    /// **is** answering `nil`: the same answer as a run that died mid-turn. `lastSummary`'s doc
    /// comment names all three facts that arrive as that one `nil`, because this signature cannot.
    ///
    /// The skip stays, on the reason that survives measurement rather than the one that did not:
    /// `continue` and `break` are indistinguishable on a one-record log, so the tolerant arm costs
    /// nothing, and on a log that somehow carried two — a concatenation, a resumed session — it
    /// returns the older record instead of nothing. That is more information, though not
    /// *newer* information, and the caller cannot tell which it got. `TurnSummary`'s own doc
    /// comment is where the undecodable case stops being hypothetical: these lines are persisted
    /// and read back by later builds, and one field added without `Optional` or `@DefaultsToEmpty`
    /// makes every log written before it undecodable at once.
    private static func last<Params: Decodable>(
        _ type: Params.Type, method: String, inLogAt url: URL
    ) -> Params? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        for line in data.split(separator: 0x0A).reversed() {
            // Re-based, because a `Data` slice keeps its parent's indices and `JSONDecoder` is
            // not owed a zero-based one. `ClaudeRun.lastResult` does the same.
            let line = Data(line)
            guard
                let envelope = try? decoder.decode(Envelope.self, from: line),
                envelope.method == method,
                let record = try? decoder.decode(Record<Params>.self, from: line)
            else { continue }
            return record.params
        }
        return nil
    }

    /// ⚠️ Non-throwing, and the fallback is unreachable by construction rather than by hope.
    /// `RunSessionInfo`, `TurnSummary` and `Refusals` are `String`/`Int`/`Bool`/array/`Double?` all
    /// the way down, and the only way `JSONEncoder` can fail on that shape is a non-finite `Double`
    /// — the single candidate being `RunUsage.costUSD`, which arrives through `JSONDecoder` off the
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
