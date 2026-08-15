import Foundation

/// What a turn amounted to. Assembled by `AgentRun` from the `session/prompt` response and
/// what it saw on the way, and written into the log as an `elliot/terminal` line (Task 9) —
/// because under ACP the `stopReason` arrives as a **response**, not a notification, so it
/// never enters the notification stream and would never reach the log on its own.
///
/// The successor to `RunResult`'s role, not its shape: `subtype`, `durationMS` and
/// `terminalReason` were stream-json's own vocabulary and have no ACP source.
///
/// ⛔ **This type is persisted — in run logs, not in the database — so every field added after
/// this one ships must be `Optional` or `@DefaultsToEmpty`.** `AgentLog.lastSummary(inLogAt:)`
/// decodes it out of `elliot/terminal` lines written by **earlier builds**, and
/// `ArtifactRetention` keeps those for 14 days and 512 MB. Swift's synthesised decoder emits
/// `decode(_:forKey:)` and ignores default values, so a new non-optional field throws
/// `keyNotFound` on every log written before it — and that scan answers `nil`, which is the same
/// answer it gives for a run that died mid-turn, on exactly the runs a reader is trying to
/// understand. (This said "silently degrading `RunScheduler.finish`"; `finish` reads the run's
/// outcome, not its log — `AgentLog.lastSummary`'s doc comment records why the two are
/// deliberately different values.) It is the `openReadOnly` trap that this
/// plan already carries for the database (Task 12), pointed at `runs/*.jsonl`, where **no
/// migration test would catch it** because there is no migration.
public struct TurnSummary: Sendable, Hashable, Codable {
    /// `end_turn | max_tokens | max_turn_requests | refusal | cancelled`, or an unrecognised
    /// string. `nil` when the response never arrived.
    public var stopReason: String?
    /// The agent's closing prose, concatenated from `agent_message_chunk`. Display only —
    /// never parsed for issue or PR numbers.
    public var text: String?
    /// Context usage as of the last `usage_update` seen, carrying the **last cost anyone
    /// reported** rather than the last frame's cost.
    ///
    /// ⛔ Two rules were written down here and they contradicted each other. This is the third,
    /// and it is the only one that is right in both directions: `used`/`size` come from the last
    /// frame, because a stale context figure is simply wrong; `costUSD` is the last **non-nil**
    /// one, so that a turn which really did cost money cannot report `nil` into
    /// `RunScheduler.finish` and on into `SkillRun.totalCostUSD`. Absence still means "nobody
    /// reported one", never zero.
    ///
    /// ⚠️ **That fallback is defensive, and the measurement this comment used to cite does not
    /// support it.** It said cost was "absent from nine frames of a turn and present on the
    /// tenth", which was one recording read as *late in the turn*. Re-derived across all four of
    /// `Fixtures/acp/turn-*.json`: cost appears on **4 of 42 `usage_update` frames — exactly once
    /// per turn, and every time on the turn's last one**, immediately before the `session/prompt`
    /// response (elements 31 of 34, 17 of 20, 18 of 21, 99 of 102). So on every recording we hold
    /// the last non-nil cost *is* the last frame's, and no recording shows the ordering this rule
    /// defends against. Kept anyway — nothing in the protocol orders those frames, and one
    /// `usage_update` arriving after the cost frame would lose the figure a person reads — but it
    /// is not evidence of an ordering anybody has seen. `AgentInvocation.maxBudgetUSD` carries the
    /// same re-derivation and what it costs the spend brake.
    public var usage: RunUsage?
    /// The `usage` field on the `session/prompt` response — a per-turn token report the ACP
    /// spec does not define and the adapter provides anyway [M].
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var totalTokens: Int?
    /// Tool names whose final patch carried a `nonExecutionKind` that `isDenial`.
    public var denials: [String]
    /// Every `nonExecutionKind` seen, denial or not — recorded, never discarded, so an
    /// unmeasured value can be found and measured rather than silently folded.
    public var nonExecutionKinds: [NonExecutionKind]
    /// How many times `LineBuffer` truncated at its 32 MB cap, as of the prompt response.
    ///
    /// ⛔ **Not a count of frames, and it must not be named as one.** `LineBuffer.append`
    /// (`LineBuffer.swift:34-37`) increments `droppedOversized` **once per chunk** for as long
    /// as `pending` stays over the limit, so one oversized line arriving in 64 KB reads reports
    /// hundreds. It is also read when the response lands, i.e. before the final drain, so it is
    /// a floor rather than a total. The only claim it supports is the binary one: **non-zero
    /// means something in this log is truncated.**
    ///
    /// ⚠️ A truncated line is **corrupted, not dropped** — it still decodes, or fails to, as
    /// half a message. `ACPTransport` counted these and nothing read the count (a #380 deferred
    /// minor, made load-bearing by Stage 1: a `{type:"diff", …}` for a whole file is exactly
    /// the frame that reaches the cap). Carrying it is what stops a reader inferring a fold bug
    /// from mangled content.
    public var truncationEvents: Int
    public var isError: Bool

    public init(
        stopReason: String? = nil, text: String? = nil, usage: RunUsage? = nil,
        inputTokens: Int? = nil, outputTokens: Int? = nil, totalTokens: Int? = nil,
        denials: [String] = [], nonExecutionKinds: [NonExecutionKind] = [],
        truncationEvents: Int = 0, isError: Bool
    ) {
        self.stopReason = stopReason
        self.text = text
        self.usage = usage
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.denials = denials
        self.nonExecutionKinds = nonExecutionKinds
        self.truncationEvents = truncationEvents
        self.isError = isError
    }

    /// A run only counts as clean if it neither errored **nor** was refused a tool along the
    /// way. The same predicate `RunResult.isClean` states, and `RunScheduler.state(for:)` reads
    /// this rather than restating it — that restatement is live today
    /// (`RunScheduler.swift:1036` re-implements `RunResult.isClean`) and Task 15 removes it.
    public var isClean: Bool { !isError && denials.isEmpty }
}

/// One line of a run log, already classified.
///
/// A run log is a *tree* flattened into a stream: a `tool_result` belongs to the
/// `tool_use` that asked for it, and the two are separated by however many lines
/// the tool took to answer. Rendering the stream verbatim loses that, so the
/// fold below reattaches every result to its call **by id** and the view gets a
/// row per act rather than a row per line.
public enum RunLogRow: Sendable, Hashable, Identifiable {
    case session(SystemInit)
    case agentText(String)
    /// `outcome == nil` means the call is still in flight — the result has not
    /// arrived yet, which is the difference between "running" and "returned
    /// nothing".
    case toolUse(name: String, id: String, input: String, outcome: ToolOutcome?)
    /// Synthesised from the run's `permissionDenials`, never decoded: the stream
    /// carries no event for a refusal. The agent sees one as an ordinary tool
    /// error and usually works around it, so it has to be its own kind of row or
    /// the run reads as clean.
    case denial(toolName: String)
    /// A result whose `tool_use` never arrived — a resumed session, a truncated
    /// log. Kept rather than dropped: an unexplained result is information.
    case orphanResult(ToolOutcome)
    case terminal(RunResult)
    /// `.malformed` or `.unknown`, raw text kept. A schema change in a future
    /// Claude Code release degrades one row instead of hiding a line.
    case unreadable(text: String)

    /// The ACP handshake's answer. `.session(SystemInit)` above is its stream-json counterpart
    /// and stays for the archive; the two carry different facts (`SystemInit` knows the tool
    /// list and the MCP servers, which ACP does not advertise), so they are two cases rather
    /// than one lossy one.
    case agentSession(RunSessionInfo)
    /// NEW. `StreamEventDecoder.decodeMessage` discarded thinking entirely.
    case thought(String)
    /// One tool call, every frame of it already folded.
    case toolCall(ToolCallPatch)
    /// NEW.
    case plan([PlanStep])
    /// Elliot's own words, not the agent's — a fact face row, never hearsay.
    case modeChanged(String)
    /// The ACP counterpart of `.terminal(RunResult)`.
    case turnEnded(TurnSummary)

    /// Stable within one fold of one log, which is what `ForEach` needs.
    ///
    /// Two rows carrying identical payloads — the same prose twice, two refusals
    /// of the same tool — collide, because the case payloads are all this has to
    /// work from. A view that must tell those apart should enumerate rather than
    /// lean on this.
    public var id: String {
        switch self {
        case .session(let info): "session:\(info.sessionID)"
        case .agentText(let text): "text:\(Self.digest(text))"
        case .toolUse(_, let id, let input, _): "tool:\(id):\(Self.digest(input))"
        case .denial(let toolName): "denial:\(toolName)"
        case .orphanResult(let outcome): "orphan:\(Self.digest(outcome.preview))"
        case .terminal(let result): "result:\(result.sessionID ?? result.subtype)"
        case .unreadable(let text): "unreadable:\(Self.digest(text))"
        case .agentSession(let info): "acpsession:\(info.agentSessionID)"
        case .thought(let text): "thought:\(Self.digest(text))"
        // ⚠️ Deliberately does not digest the payload: a `ToolCallPatch` is refined frame by
        // frame, so digesting it would change the row's identity mid-run and make `ForEach` tear
        // it down and rebuild it on every patch. `.toolUse` above digests its `input` because
        // that row is replaced wholesale instead — a different case, a different rule.
        case .toolCall(let call): "call:\(call.id)"
        case .plan(let steps): "plan:\(Self.digest(steps.map(\.content).joined()))"
        case .modeChanged(let mode): "mode:\(Self.digest(mode))"
        case .turnEnded(let summary): "turn:\(summary.stopReason ?? "?")"
        }
    }

    /// FNV-1a. `hashValue` is seeded per process, so it would hand the same row
    /// a different identity on the next launch; this does not.
    private static func digest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 36)
    }
}

/// What a tool call came back with, as far as the log can tell.
public struct ToolOutcome: Sendable, Hashable {
    public var isError: Bool
    public var preview: String

    public init(isError: Bool, preview: String) {
        self.isError = isError
        self.preview = preview
    }
}

public enum RunLogFilter: String, CaseIterable, Sendable {
    case all
    case tools
    case errors
}

public enum RunLog {
    /// Folds a decoded stream into rows.
    ///
    /// A `.toolResult` attaches to the `.toolUse` whose `id` matches — by id,
    /// never by arrival order, because two tools can be in flight at once and
    /// their results can come back in either order. An unmatched result becomes
    /// `.orphanResult` rather than being dropped. `.system` and `.partial` are
    /// dropped; `.malformed` and `.unknown` survive as `.unreadable`.
    ///
    /// `denials` are tool names taken from the run itself (`SkillRun`) rather
    /// than from the stream, which has no event for them. They are inserted
    /// immediately before the terminal row: the log only learns of a refusal
    /// when the run ends, and a row after the terminal one would read as
    /// something that happened after the run finished.
    public static func rows(from events: [StreamEvent], denials: [String] = []) -> [RunLogRow] {
        var rows: [RunLogRow] = []
        // Row index of the most recent `.toolUse` seen for each tool_use id.
        var indexByID: [String: Int] = [:]

        for event in events {
            switch event {
            case .systemInit(let info):
                rows.append(.session(info))

            case .assistantText(let text):
                rows.append(.agentText(text))

            case .assistantToolUse(let name, let id, let inputPreview):
                rows.append(.toolUse(name: name, id: id, input: inputPreview, outcome: nil))
                // A repeated id would be a protocol violation; letting the most
                // recent call win keeps a result landing on a row still waiting
                // for one.
                indexByID[id] = rows.count - 1

            case .toolResult(let toolUseID, let isError, let preview):
                let outcome = ToolOutcome(isError: isError, preview: preview)
                guard
                    let index = indexByID[toolUseID],
                    case .toolUse(let name, let id, let input, _) = rows[index]
                else {
                    rows.append(.orphanResult(outcome))
                    continue
                }
                rows[index] = .toolUse(name: name, id: id, input: input, outcome: outcome)

            case .result(let result):
                rows.append(.terminal(result))

            case .unknown(_, let raw):
                rows.append(.unreadable(text: String(decoding: raw, as: UTF8.self)))

            case .malformed(let raw, _):
                rows.append(.unreadable(text: String(decoding: raw, as: UTF8.self)))

            case .system, .partial:
                continue
            }
        }

        guard !denials.isEmpty else { return rows }
        let denialRows = denials.map { RunLogRow.denial(toolName: $0) }
        let terminal = rows.firstIndex { if case .terminal = $0 { true } else { false } }
        guard let terminal else { return rows + denialRows }
        rows.insert(contentsOf: denialRows, at: terminal)
        return rows
    }

    /// Folds an ACP run into rows.
    ///
    /// ⛔ The one difference from `rows(from: [StreamEvent])` above is the whole point: a
    /// `ToolCallPatch` **merges** into the row it lands on. `nil` is absent-from-this-frame,
    /// never cleared — measured on `Fixtures/acp/turn-edit-bash.json`, where the `Edit` call's
    /// last frame carries `status: "completed"` and nothing else at all. Replacing leaves the
    /// finished card with no title and no kind.
    ///
    /// `.usage` produces no row: it is a running figure, and a row per frame would bury the
    /// log. It is carried onto `.turnEnded` instead, by the rule `TurnSummary.usage` states —
    /// the last frame's `used`/`size`, and the last **non-nil** `costUSD`.
    public static func rows(
        from events: [RunEvent], denials: [String] = [], summary: TurnSummary? = nil
    ) -> [RunLogRow] {
        var rows: [RunLogRow] = []
        var indexByID: [String: Int] = [:]
        var lastUsage: RunUsage?
        var lastCostUSD: Double?

        for event in events {
            switch event {
            case .session(let info):
                rows.append(.agentSession(info))
            case .agentText(let text):
                rows.append(.agentText(text))
            case .agentThought(let text):
                rows.append(.thought(text))
            case .toolCall(let patch):
                if let index = indexByID[patch.id], case .toolCall(let existing) = rows[index] {
                    rows[index] = .toolCall(existing.merging(patch))
                } else {
                    rows.append(.toolCall(patch))
                    indexByID[patch.id] = rows.count - 1
                }
            case .plan(let steps):
                rows.append(.plan(steps))
            case .usage(let usage):
                lastUsage = usage
                if let cost = usage.costUSD { lastCostUSD = cost }
            case .modeChanged(let mode):
                rows.append(.modeChanged(mode))
            case .unreadable(let raw, _):
                rows.append(.unreadable(text: String(decoding: raw, as: UTF8.self)))
            }
        }

        if var summary {
            if summary.usage == nil, var usage = lastUsage {
                usage.costUSD = usage.costUSD ?? lastCostUSD
                summary.usage = usage
            }
            rows.append(.turnEnded(summary))
        }

        guard !denials.isEmpty else { return rows }
        let denialRows = denials.map { RunLogRow.denial(toolName: $0) }
        let turn = rows.firstIndex { if case .turnEnded = $0 { true } else { false } }
        guard let turn else { return rows + denialRows }
        rows.insert(contentsOf: denialRows, at: turn)
        return rows
    }

    /// `.tools` keeps `.toolUse` and `.toolCall`; `.errors` keeps `.denial`, a `.toolUse` whose
    /// outcome `isError`, an `.orphanResult` whose outcome `isError`, a `.terminal` that is not
    /// clean, a `.toolCall` whose `status == .failed`, and a `.turnEnded` that is not `isClean`.
    /// Nothing else — a tool still in flight has not failed, and an unreadable line is not an
    /// error the agent hit. `.agentSession`, `.thought`, `.plan` and `.modeChanged` are kept by
    /// neither.
    public static func filter(_ rows: [RunLogRow], by filter: RunLogFilter) -> [RunLogRow] {
        switch filter {
        case .all:
            return rows

        case .tools:
            // ⛔ No `default:` here, for the same reason `.errors` below has none: a fourteenth
            // row case must break the build at this switch rather than be silently dropped from
            // the Tools filter. A `default` is the one way this file can acquire a new case
            // without deciding about it — which is exactly how the six ACP cases would have
            // arrived, had this arm been written that way before they landed.
            return rows.filter {
                switch $0 {
                case .toolUse, .toolCall: return true
                case .session, .agentText, .denial, .orphanResult, .terminal, .unreadable,
                    .agentSession, .thought, .plan, .modeChanged, .turnEnded:
                    return false
                }
            }

        case .errors:
            return rows.filter {
                switch $0 {
                case .denial: return true
                case .toolUse(_, _, _, let outcome): return outcome?.isError == true
                case .orphanResult(let outcome): return outcome.isError
                case .terminal(let result): return !result.isClean
                case .toolCall(let call): return call.status == .failed
                case .turnEnded(let summary): return !summary.isClean
                case .session, .agentText, .unreadable,
                    .agentSession, .thought, .plan, .modeChanged:
                    return false
                }
            }
        }
    }
}

/// The two halves of what a finished run amounts to, kept apart on purpose.
///
/// `closing` is what the run left behind **and whose words they are**. `ghSays`
/// is derived from `verifiedOutcome`, which `Verifier` obtained from
/// `gh … --json`. The app's whole epistemology is that these are different kinds
/// of thing, and this type is where that stops being a convention.
///
/// ⚠️ The claim side used to be a bare `itSaid: String?`, and that name was the
/// bug: it asserted an author the field could not vouch for. A run that died
/// before its terminal event stored *stderr* there, and a run Elliot could not
/// start stored a sentence Elliot had written — both rendered as the agent's
/// prose, in the one block built to say which of two things may be believed
/// (#288). `itSaid` survives below as the hearsay half only, and it is now a
/// question the type can answer rather than a label it applies by default.
public struct RunVerdict: Sendable, Hashable {
    /// What the run had to say for itself, attributed. Never parsed.
    public var closing: ClosingRemark?
    /// `run.verifiedOutcome?.receiptText`. Fact face.
    public var ghSays: String?

    public init(closing: ClosingRemark? = nil, ghSays: String? = nil) {
        self.closing = closing
        self.ghSays = ghSays
    }

    /// The agent's own prose, and only ever that.
    ///
    /// Stderr and Elliot's own notes cannot appear here whatever the run
    /// stored, because this reads the attribution rather than the field. That
    /// is the guarantee the old spelling could not make.
    public var itSaid: String? {
        closing.flatMap { $0.isHearsay ? $0.text : nil }
    }

    /// Splits a run into what it said and what `gh` found. Pure, and nothing on
    /// the `ghSays` side can come from the closing text, whatever that text
    /// happens to claim — nor, now, can the closing text be taken for the
    /// agent's when it was the process's.
    public static func of(_ run: SkillRun) -> RunVerdict {
        RunVerdict(
            closing: run.closing?.trimmed(),
            ghSays: run.verifiedOutcome?.receiptText
        )
    }
}

public extension VerifiedOutcome {
    /// The text half of what `gh` established. `Consequence.receipt` in
    /// `ElliotAppKit` decorates it with a tint and an icon — one wording, one
    /// place, and reachable from `ElliotModelTests`, which cannot import the app
    /// layer.
    var receiptText: String {
        switch self {
        case .issueCreated(let number, _):
            "Opened issue #\(number)"
        case .noIssueCreated(let reason):
            "No issue — \(reason)"
        case .prOpen(let number, _, let isDraft, let branch):
            "\(isDraft ? "Draft PR" : "PR") \(number) on \(branch)"
        case .merged(let sha, _, _, _):
            "Merged\(sha.map { " as \($0.prefix(7))" } ?? "")"
        case .notMerged(let reason):
            "Not merged — \(reason)"
        case .closedUnmerged:
            "Closed without merging"
        case .unverified(let reason):
            "Unverified — \(reason)"
        }
    }
}
