import ElliotModel
import SwiftUI

/// One view per `RunLogRow` case.
///
/// The log used to be `[String]`: every event flattened to one line, set in one
/// face, and a *successful* tool result thrown away before any view could ask
/// for it. A run in flight therefore read as a list of things the agent had
/// started and nothing it had finished.
///
/// The rule the whole file is written to is the app's own: **monospace means a
/// machine established it.** A tool's name, its arguments and what it returned
/// are set in `Type.fact`; the agent's prose is set in `Type.hearsay`, demoted
/// and italic. The contrast is the feature — it says which of the two you are
/// reading before a word of either has been.
///
/// Every row is one combined accessibility element whose label leads with its
/// kind, and the glyph that opens it is hidden: a screen reader hears "Tool
/// use, Bash…", never a symbol name.
struct LogRowView: View {
    var row: RunLogRow

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: Self.glyph(for: row))
                .font(Type.factSmall)
                .foregroundStyle(Self.glyphTint(for: row))
                .frame(width: 13, alignment: .center)
                .accessibilityHidden(true)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(LogRowAccessibility.label(for: row))
    }

    @ViewBuilder
    private var content: some View {
        switch row {
        case .session(let info):
            SessionRow(info: info)

        case .agentText(let text):
            AgentTextRow(text: text)

        case .toolUse(let name, _, let input, let outcome):
            ToolUseRow(name: name, input: input, outcome: outcome)

        case .denial(let toolName):
            DenialRow(toolName: toolName)

        case .orphanResult(let outcome):
            OrphanResultRow(outcome: outcome)

        case .terminal(let result):
            TerminalRow(result: result)

        case .unreadable(let text):
            UnreadableRow(text: text)
        }
    }

    /// The symbol that opens a row. Hidden from VoiceOver, so it carries no
    /// meaning a sighted reader gets and a listening one does not — the label
    /// says the kind in words.
    nonisolated static func glyph(for row: RunLogRow) -> String {
        switch row {
        case .session: "power"
        case .agentText: "quote.bubble"
        case .toolUse: "chevron.left.forwardslash.chevron.right"
        case .denial: "lock.slash"
        case .orphanResult: "arrow.uturn.left"
        case .terminal: "flag.checkered"
        case .unreadable: "questionmark.square.dashed"
        }
    }

    /// Greyscale unless the row is a *consequence*. A failing tool and a run
    /// that ended badly earn `refused`; everything else — including a refusal,
    /// which the mockup drew in amber — stays in the type tiers. The five
    /// accents only mean anything while they stay scarce.
    nonisolated static func glyphTint(for row: RunLogRow) -> Color {
        switch row {
        case .toolUse(_, _, _, let outcome):
            outcome?.isError == true ? Palette.refused : Palette.quiet
        case .orphanResult(let outcome):
            outcome.isError ? Palette.refused : Palette.quiet
        case .terminal(let result):
            result.isClean ? Palette.verified : Palette.refused
        case .session, .agentText, .denial, .unreadable:
            Palette.quiet
        }
    }
}

// MARK: - Session init

/// What the session was started as, as chips: model, permission mode, how many
/// tools it was given, and where it is running.
///
/// Chips rather than a sentence because these are four independent facts, and
/// the one that matters most — the permission mode — is the one a sentence
/// buries in the middle.
/// Internal rather than private only so `LogRowAccessibility` can reach
/// `chips(_:)`: what VoiceOver hears and what is drawn are then one list, not
/// two that drift.
struct SessionRow: View {
    var info: SystemInit

    var body: some View {
        InlineFlow(spacing: 4, lineSpacing: 3) {
            ForEach(Self.chips(info), id: \.self) { chip in
                MonoChip(text: chip)
            }
        }
    }

    /// Only what the line actually carried. A missing model is not "claude" —
    /// the app does not know which one, and inventing the usual answer here is
    /// how a log stops being a record.
    nonisolated static func chips(_ info: SystemInit) -> [String] {
        var out: [String] = []
        if let model = info.model, !model.isEmpty { out.append(model) }
        if let mode = info.permissionMode, !mode.isEmpty { out.append(mode) }
        out.append(info.tools.count == 1 ? "1 tool" : "\(info.tools.count) tools")
        if let cwd = info.cwd, !cwd.isEmpty { out.append(abbreviated(cwd)) }
        return out
    }

    /// The last two components, with the elision spelled out. A run's `cwd` is
    /// an absolute path and the panel is 344pt wide; the alternative is a chip
    /// that truncates without saying so.
    nonisolated static func abbreviated(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count > 2 else { return path }
        return "…/" + parts.suffix(2).joined(separator: "/")
    }
}

// MARK: - Agent prose

/// What the agent said, demoted.
///
/// `Type.hearsay` — italic proportional — is the deliberate opposite of the
/// fact face used by every other row here. Nothing on this line is ever parsed;
/// it is displayed and that is all.
private struct AgentTextRow: View {
    var text: String

    var body: some View {
        Text(text)
            .font(Type.hearsay)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

// MARK: - Tool use, with its result under it

/// A call and what it came back with, as one row.
///
/// The result is nested under the call rather than listed after it because the
/// stream is a tree flattened into a line: `RunLog.rows` reattached the two by
/// id, and drawing them apart again would throw that away. A **successful**
/// result gets a line of its own — it had none at all before, which made a run
/// in flight read as a list of unfinished work.
private struct ToolUseRow: View {
    var name: String
    var input: String
    var outcome: ToolOutcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                MonoChip(text: name)
                Text(input)
                    .font(Type.fact)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
            ToolResultLine(outcome: outcome)
        }
    }
}

/// The nested half of a tool row: a rule, a verdict glyph, and the preview.
///
/// `nil` is not "returned nothing" — it is "has not returned yet", and saying
/// so is the difference between a run that is working and a run that is stuck.
private struct ToolResultLine: View {
    var outcome: ToolOutcome?

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Rectangle()
                .fill(Surface.hairline)
                .frame(width: 1)
                .accessibilityHidden(true)
            Image(systemName: symbol)
                .font(Type.factSmall)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(outcome == nil ? Type.prose : Type.fact)
                .foregroundStyle(outcome == nil ? Palette.quiet : .secondary)
                .lineLimit(3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 3)
    }

    private var symbol: String {
        guard let outcome else { return "ellipsis" }
        return outcome.isError ? "xmark" : "checkmark"
    }

    private var tint: Color {
        guard let outcome else { return Palette.quiet }
        return outcome.isError ? Palette.refused : Palette.verified
    }

    private var text: String {
        guard let outcome else { return "still running" }
        return outcome.preview
    }
}

// MARK: - Refusal

/// A tool the run was refused.
///
/// Greyscale on purpose. The agent sees a denial as an ordinary tool error and
/// usually carries on around it, so the row has to exist — but the run's own
/// state line already spends `attention` saying "finished, tools refused", and
/// a second accent for the same fact would only dilute the first.
private struct DenialRow: View {
    var toolName: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("Refused:")
                .font(Type.prose)
                .foregroundStyle(.secondary)
            Fact(text: toolName, tint: .primary)
            Text("— the run carried on around it")
                .font(Type.prose)
                .foregroundStyle(Palette.quiet)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - A result with no call

/// A result whose `tool_use` is not in this log — a resumed session, a
/// truncated file. Kept rather than dropped: an unexplained result is
/// information, and silently discarding it is how a log starts lying by
/// omission.
private struct OrphanResultRow: View {
    var outcome: ToolOutcome

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Result with no call in this log")
                .font(Type.prose)
                .foregroundStyle(Palette.quiet)
            Text(outcome.preview)
                .font(Type.fact)
                .foregroundStyle(outcome.isError ? Palette.refused : .secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - The closing line

/// How the run ended, in the fact face, with the agent's parting prose demoted
/// under it.
///
/// The two halves are the same split the verdict block makes: the exit, the
/// turn count and the duration came from the process, and the sentence came
/// from the agent.
/// Internal for the same reason as `SessionRow`: `summary(_:)` is both drawn
/// and spoken.
struct TerminalRow: View {
    var result: RunResult

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Fact(
                text: Self.summary(result),
                tint: result.isClean ? Palette.verified : Palette.refused
            )
            if let text = result.text, !text.isEmpty {
                Text(text)
                    .font(Type.hearsay)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    /// Only the fields the line carried. `RunResult` makes all three optional
    /// and a fabricated "0 turns" would read as a measurement.
    nonisolated static func summary(_ result: RunResult) -> String {
        var parts = [result.isClean ? "Finished clean" : "Finished with issues"]
        if let turns = result.numTurns {
            parts.append(turns == 1 ? "1 turn" : "\(turns) turns")
        }
        if let ms = result.durationMS {
            parts.append(String(format: "%.1f s", Double(ms) / 1000))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - A line nothing could read

/// `.malformed` or `.unknown`, raw. A schema change in a future Claude Code
/// release degrades one row instead of hiding a line.
private struct UnreadableRow: View {
    var text: String

    var body: some View {
        Text(text)
            .font(Type.log)
            .foregroundStyle(Palette.quiet)
            .lineLimit(3)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - What a screen reader hears

/// Pure, and in one place, because *every row is one combined element whose
/// label leads with its kind* is a rule — and a rule written seven times inside
/// seven `body`s is a rule nothing can check.
enum LogRowAccessibility {

    /// The word a row's label starts with.
    static func kind(of row: RunLogRow) -> String {
        switch row {
        case .session: "Session"
        case .agentText: "It said"
        case .toolUse: "Tool use"
        case .denial: "Refused"
        case .orphanResult: "Tool result"
        case .terminal: "Result"
        case .unreadable: "Unreadable line"
        }
    }

    static func label(for row: RunLogRow) -> String {
        let kind = kind(of: row)
        switch row {
        case .session(let info):
            return "\(kind), \(SessionRow.chips(info).joined(separator: ", "))"

        case .agentText(let text):
            return "\(kind), \(text)"

        case .toolUse(let name, _, let input, let outcome):
            return "\(kind), \(name), \(input). \(spoken(outcome))"

        case .denial(let toolName):
            return "\(kind), \(toolName). The run carried on around it."

        case .orphanResult(let outcome):
            return "\(kind), no matching call in this log. \(outcome.preview)"

        case .terminal(let result):
            let closing = result.text.map { " \($0)" } ?? ""
            return "\(kind), \(TerminalRow.summary(result)).\(closing)"

        case .unreadable(let text):
            return "\(kind), \(text)"
        }
    }

    /// A call still in flight has not failed. Saying "succeeded" for a missing
    /// result, or "failed" for one, would each be a claim the log cannot make.
    private static func spoken(_ outcome: ToolOutcome?) -> String {
        guard let outcome else { return "Still running." }
        return "\(outcome.isError ? "Failed" : "Succeeded"), \(outcome.preview)"
    }
}
