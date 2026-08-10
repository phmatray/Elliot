import Foundation

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

    /// `.tools` keeps `.toolUse`; `.errors` keeps `.denial`, a `.toolUse` whose
    /// outcome `isError`, an `.orphanResult` whose outcome `isError`, and a
    /// `.terminal` that is not clean. Nothing else — a tool still in flight has
    /// not failed, and an unreadable line is not an error the agent hit.
    public static func filter(_ rows: [RunLogRow], by filter: RunLogFilter) -> [RunLogRow] {
        switch filter {
        case .all:
            return rows

        case .tools:
            return rows.filter {
                if case .toolUse = $0 { return true }
                return false
            }

        case .errors:
            return rows.filter {
                switch $0 {
                case .denial: return true
                case .toolUse(_, _, _, let outcome): return outcome?.isError == true
                case .orphanResult(let outcome): return outcome.isError
                case .terminal(let result): return !result.isClean
                case .session, .agentText, .unreadable: return false
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
