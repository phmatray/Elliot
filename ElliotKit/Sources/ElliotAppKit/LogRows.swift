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

        case .agentSession(let info):
            AgentSessionRow(info: info)

        case .thought(let text):
            ThoughtRow(text: text)

        case .toolCall(let call):
            ToolCallRow(call: call)

        case .plan(let steps):
            PlanRow(steps: steps)

        case .modeChanged(let mode):
            ModeChangedRow(mode: mode)

        case .turnEnded(let summary):
            TurnEndedRow(summary: summary)
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
        case .agentSession: "power"
        case .thought: "brain"
        // The only row whose glyph is decided by its payload: a `Read` and an
        // `Edit` are the same case and different acts, and the glyph is what
        // tells them apart before a word is read.
        case .toolCall(let call): ToolCallRow.glyph(for: call.kind)
        case .plan: "list.bullet.clipboard"
        case .modeChanged: "arrow.left.arrow.right"
        case .turnEnded: "flag.checkered"
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
        case .toolCall(let call):
            call.status == .failed ? Palette.refused : Palette.quiet
        case .turnEnded(let summary):
            summary.isClean ? Palette.verified : Palette.refused
        case .session, .agentText, .denial, .unreadable,
            .agentSession, .thought, .plan, .modeChanged:
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

    /// The last two components, with the elision spelled out.
    ///
    /// A run's `cwd` is an absolute path, and no width the panel can take makes
    /// one fit. The panel is measured in columns rather than in points —
    /// `PanelLayout.panelWidth` is two or three of them — and at three spans it
    /// splits between both panes, so this one gets a column and a half there
    /// and two columns at the narrow setting, where it is the only pane shown.
    /// The alternative is a chip that truncates without saying so.
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

// MARK: - The ACP handshake

/// What the agent said it was, as chips: model, permission mode, which agent
/// answered, and where it is running.
///
/// `SessionRow` above is the stream-json counterpart and stays for the archive.
/// The two are not one view because they do not know the same things: a
/// `SystemInit` carries the tool list and the MCP servers and ACP advertises
/// neither, so a shared view would have to invent a tool count or drop a fact
/// the archive really has.
/// Internal rather than private for the same reason `SessionRow` is:
/// `LogRowAccessibility` reaches `chips(_:)`, so what is drawn and what is
/// spoken are one list rather than two that drift.
struct AgentSessionRow: View {
    var info: RunSessionInfo

    var body: some View {
        InlineFlow(spacing: 4, lineSpacing: 3) {
            ForEach(Self.chips(info), id: \.self) { chip in
                MonoChip(text: chip)
            }
        }
    }

    /// Only what the handshake carried. A missing model is not "claude" and a
    /// missing mode is not "bypassPermissions" — the second guess would be the
    /// dangerous one, since the mode is exactly what bounds what an unattended
    /// run may do.
    ///
    /// Name and version fold into one chip because they are one fact read
    /// together, and a version with no name says nothing at all.
    nonisolated static func chips(_ info: RunSessionInfo) -> [String] {
        var out: [String] = []
        if let model = info.model, !model.isEmpty { out.append(model) }
        if let mode = info.mode, !mode.isEmpty { out.append(mode) }
        if let name = info.agentName, !name.isEmpty {
            if let version = info.agentVersion, !version.isEmpty {
                out.append("\(name) \(version)")
            } else {
                out.append(name)
            }
        }
        if !info.cwd.isEmpty { out.append(SessionRow.abbreviated(info.cwd)) }
        return out
    }
}

// MARK: - What the agent was thinking

/// The agent's thinking, demoted twice.
///
/// `Type.hearsay` says *this is a claim, not a fact* — which is what
/// `AgentTextRow` says too. Thinking is a step below that again: prose the
/// agent addressed to nobody, and which stream-json discarded outright
/// (`StreamEventDecoder.decodeMessage`'s `default: continue`). The third
/// greyscale tier carries that extra step down, so it costs none of the five
/// accents.
private struct ThoughtRow: View {
    var text: String

    var body: some View {
        Text(text)
            .font(Type.hearsay)
            .foregroundStyle(Palette.quiet)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

// MARK: - A tool call, every frame of it folded

/// One tool call as it stands right now.
///
/// `ToolUseRow` above draws a call that was *replaced* by its result; this
/// draws one that was **merged** frame by frame, which is why the status sits
/// on the call itself rather than on a nested result line. What a frame omitted
/// was never cleared — `ToolCallPatch.merging` is where that is decided — so
/// every field here is drawn if the fold was ever told one, whichever frame
/// told it.
private struct ToolCallRow: View {
    var call: ToolCallPatch

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                MonoChip(text: Self.name(call))
                if let title = call.title, !title.isEmpty {
                    Text(title)
                        .font(Type.fact)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                }
                StatusPip(status: call.status)
            }

            if let line = Self.locations(call) {
                Fact(text: line, tint: Palette.quiet, small: true)
            }

            if let kind = call.nonExecutionKind {
                Fact(text: Self.nonExecution(kind), tint: Palette.quiet, small: true)
            }

            if let content = call.content {
                ForEach(Array(content.enumerated()), id: \.offset) { item in
                    ToolContentView(content: item.element)
                }
            }
        }
    }

    /// `claudeToolName` is the adapter's own `_meta` and the most useful thing
    /// on the frame; `kind` is the protocol's coarser word for the same act.
    /// With neither, the **id** — the one field every frame is guaranteed to
    /// carry — rather than a guessed name. A chip reading "tool" would be this
    /// app inventing the usual answer, which is the habit `SessionRow.chips`
    /// refuses two hundred lines up.
    nonisolated static func name(_ call: ToolCallPatch) -> String {
        call.claudeToolName ?? call.kind?.rawValue ?? call.id
    }

    /// An unrecognised kind gets the glyph an unreadable line gets: ACP's kind
    /// list is open, so this says "shipped after this build" rather than
    /// pretending the call is something else. A frame that named no kind at all
    /// gets the neutral tool glyph, which is what `.toolUse` has always used.
    nonisolated static func glyph(for kind: ToolCallKind?) -> String {
        guard let kind else { return "chevron.left.forwardslash.chevron.right" }
        switch kind {
        case .read: return "doc.text"
        case .edit: return "pencil"
        case .delete: return "trash"
        case .move: return "arrow.right.square"
        case .search: return "magnifyingglass"
        case .execute: return "terminal"
        case .think: return "brain"
        case .fetch: return "arrow.down.circle"
        case .switchMode: return "arrow.left.arrow.right"
        case .plan: return "list.bullet.clipboard"
        case .exitPlanMode: return "arrow.uturn.up"
        case .other: return "chevron.left.forwardslash.chevron.right"
        case .unrecognised: return "questionmark.square.dashed"
        }
    }

    /// The files the call named, abbreviated the way a session's `cwd` is: the
    /// panel is two or three board columns wide and an absolute path fits in
    /// none of them.
    nonisolated static func locations(_ call: ToolCallPatch) -> String? {
        guard let locations = call.locations, !locations.isEmpty else { return nil }
        let drawn = locations.map { location in
            let path = SessionRow.abbreviated(location.path)
            return location.line.map { "\(path):\($0)" } ?? path
        }
        return drawn.joined(separator: ", ")
    }

    /// ⛔ An **unmeasured** kind has to be legible as unmeasured.
    /// `TurnSummary.nonExecutionKinds` records one; recording is not the same
    /// as showing it, and a kind nobody has measured that reaches no row is a
    /// fact nothing can act on. So the row prints it, and says in words that it
    /// is not being counted as a refusal — `NonExecutionKind.isDenial` folds by
    /// value, and an unknown value reads as *not* a denial on purpose.
    nonisolated static func nonExecution(_ kind: NonExecutionKind) -> String {
        if case .unrecognised(let raw) = kind {
            return "did not execute: \(raw) — unmeasured, not counted as a refusal"
        }
        return "did not execute: \(kind.rawValue)"
    }

    /// Both drawn and spoken.
    nonisolated static func spoken(_ call: ToolCallPatch) -> String {
        var parts = [name(call)]
        if let title = call.title, !title.isEmpty { parts.append(title) }
        parts.append(StatusPip.spoken(call.status))
        if let line = locations(call) { parts.append(line) }
        if let kind = call.nonExecutionKind { parts.append(nonExecution(kind)) }
        return parts.joined(separator: ", ")
    }
}

/// Where a tool call has got to, as a glyph and a word.
///
/// `nil` is not "pending" — it is "no frame has said yet", the same distinction
/// `ToolResultLine` draws when it says *still running* rather than nothing.
private struct StatusPip: View {
    var status: ToolCallStatus?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: Self.symbol(status))
                .font(Type.factSmall)
                .foregroundStyle(Self.tint(status))
                .accessibilityHidden(true)
            Fact(text: Self.spoken(status), tint: Self.tint(status), small: true)
        }
    }

    nonisolated static func symbol(_ status: ToolCallStatus?) -> String {
        guard let status else { return "circle.dashed" }
        switch status {
        case .pending: return "clock"
        case .inProgress: return "ellipsis"
        case .completed: return "checkmark"
        case .failed: return "xmark"
        }
    }

    /// The same two accents `ToolResultLine` spends, on the same fact: a tool
    /// that failed and a tool that came back. Nothing new is minted here.
    nonisolated static func tint(_ status: ToolCallStatus?) -> Color {
        guard let status else { return Palette.quiet }
        switch status {
        case .completed: return Palette.verified
        case .failed: return Palette.refused
        case .pending, .inProgress: return Palette.quiet
        }
    }

    nonisolated static func spoken(_ status: ToolCallStatus?) -> String {
        guard let status else { return "no status yet" }
        switch status {
        case .pending: return "pending"
        case .inProgress: return "in progress"
        case .completed: return "completed"
        case .failed: return "failed"
        }
    }
}

/// One piece of what a tool call has produced.
private struct ToolContentView: View {
    var content: ToolContent

    var body: some View {
        switch content {
        case .text(let text):
            Text(text)
                .font(Type.fact)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

        case .diff(let path, let oldText, let newText):
            DiffLinesView(path: path, oldText: oldText, newText: newText)

        case .terminal(let id):
            Fact(text: "terminal \(id)", tint: Palette.quiet, small: true)
        }
    }
}

/// One line of a rendered edit.
///
/// Internal rather than private because `DiffLinesView.lines` returns it and
/// `PanelTruncationTests` reads that answer — the cap and the true total are a
/// choice, and this project's rule is that a choice a view makes lives in a
/// pure function a test can call.
struct DiffLine: Hashable {
    var marker: String
    var text: String
    var isRemoval: Bool
}

/// The edit a tool is about to make, before the write lands.
///
/// ⚠️ **Greyscale on purpose, and the omission is the decision.** Every diff
/// anyone has read is red and green, and this one is not: `DesignSystem`
/// spends colour on *consequence* and grants exactly one exception — syntax
/// colour inside a code fence — whose own comment says a second one "should be
/// argued at least as hard as that one was", and that one was argued against an
/// approved mockup. There is no mockup for this and no approval, so the `+`/`-`
/// gutter carries the distinction and the third greyscale tier carries the
/// demotion. A coloured diff is a trade to make deliberately, not one to
/// acquire by writing a view.
///
/// ⚠️ It renders **whole lines**, it does not compute a diff. ACP hands over
/// the old text and the new text; inventing a minimal edit script between them
/// would be this view claiming to know which lines the agent thought it was
/// changing. `oldText == nil` is a file being created, which is why that draws
/// as additions and nothing else.
///
/// ⚠️ Its layout is unverified — `swift test` cannot see one — and the
/// on-screen pass is Task 17's. What a test *can* see is the cap, which is why
/// `lines(oldText:newText:limit:)` is a pure static and why this view is
/// internal rather than private.
struct DiffLinesView: View {
    var path: String
    var oldText: String?
    var newText: String

    /// Past this a row stops being a row. A whole-file `.diff` is exactly the
    /// frame `TurnSummary.truncationEvents` warns about, so drawing every line
    /// of one would bury the log the panel exists to read.
    ///
    /// `nonisolated` because `lines` is: a `View` is `@MainActor`, so its
    /// statics are too, and a main-actor default value in a nonisolated
    /// signature does not compile.
    nonisolated static let lineLimit = 40

    var body: some View {
        // Read once. This was a computed property, and `body` reads it three
        // times — the `ForEach`, then both halves of the footer — so a
        // whole-file diff was split three times over on every re-evaluation of
        // a panel that re-renders as rows stream in.
        let diff = Self.lines(oldText: oldText, newText: newText)

        VStack(alignment: .leading, spacing: 1) {
            Fact(text: SessionRow.abbreviated(path), tint: Palette.quiet, small: true)

            ForEach(Array(diff.rows.enumerated()), id: \.offset) { item in
                HStack(alignment: .top, spacing: 4) {
                    Text(item.element.marker)
                        .font(Type.factSmall)
                        .foregroundStyle(Palette.quiet)
                        .frame(width: 7, alignment: .leading)
                        .accessibilityHidden(true)
                    Text(item.element.text)
                        .font(Type.log)
                        .foregroundStyle(item.element.isRemoval ? Palette.quiet : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            if diff.total > diff.rows.count {
                Fact(
                    text: "… \(diff.total - diff.rows.count) more line(s) not shown",
                    tint: Palette.quiet, small: true
                )
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.well)
        .clipShape(RoundedRectangle(cornerRadius: Metric.nestedRadius, style: .continuous))
    }

    /// Removals then additions, each whole — at most `limit` of them, plus how
    /// many lines there really were. See the ⚠️ above for why this is not a
    /// diff algorithm.
    ///
    /// ⛔ **The cap is applied while building, never after.** `.prefix(40)` over
    /// a materialised array bounds what is *drawn* and not what is *computed*:
    /// it splits both texts in full and allocates a `DiffLine` and a `String`
    /// per line of the file first, so the protection the ⚠️ above claims would
    /// be half present — and a whole-file `.diff` is precisely the frame this
    /// view expects to be handed. `maxSplits` keeps the split's own array
    /// bounded too: past the budget the remainder arrives as one trailing
    /// piece, which `prefix` drops. The total is counted by walking the text,
    /// which allocates nothing.
    ///
    /// The budget is shared: 30 lines removed leaves room for 10 added, because
    /// what the cap bounds is rows on screen and both kinds are rows.
    nonisolated static func lines(
        oldText: String?, newText: String, limit: Int = lineLimit
    ) -> (rows: [DiffLine], total: Int) {
        var rows: [DiffLine] = []
        var total = 0

        func take(_ text: String, marker: String, isRemoval: Bool) {
            // ⛔ The count and the split must use ONE notion of a line, and they
            // now share it by construction rather than by assertion: both ask
            // `Character.isNewline`. Counting `\n` *bytes* while splitting on the
            // *Character* `"\n"` was two notions wearing one name — `\r\n` is a
            // single grapheme cluster and is not equal to `Character("\n")`, so
            // CRLF text counted as N lines and split into exactly one. It drew the
            // whole file as one unreadable row under a footer announcing lines
            // withheld that were not. The comment that stood here asserted the two
            // agreed, and asserting it is what let them drift apart.
            // `isNewline` also consumes the `\r`, so no carriage return reaches a
            // row to draw as a stray glyph. `PanelTruncationTests` pins all of it.
            // An empty text is one empty line, which is what it draws as.
            total += 1 + text.count { $0.isNewline }
            let room = limit - rows.count
            guard room > 0 else { return }
            let pieces = text.split(
                maxSplits: room, omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
            for line in pieces.prefix(room) {
                rows.append(DiffLine(marker: marker, text: String(line), isRemoval: isRemoval))
            }
        }

        if let oldText, !oldText.isEmpty {
            take(oldText, marker: "-", isRemoval: true)
        }
        take(newText, marker: "+", isRemoval: false)
        return (rows, total)
    }
}

// MARK: - The plan the agent is working to

/// One line per step, with what has become of it.
///
/// The step's words are the agent's, so they are set in `Type.hearsay` for the
/// same reason `AgentTextRow`'s are — a plan is a claim about the future, and
/// the most confident thing in this app should never be its intentions. The
/// status beside it came off the wire, so that half is a fact.
private struct PlanRow: View {
    var steps: [PlanStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(steps.enumerated()), id: \.offset) { item in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: Self.symbol(item.element.status))
                        .font(Type.factSmall)
                        .foregroundStyle(Self.tint(item.element.status))
                        .frame(width: 11, alignment: .center)
                        .accessibilityHidden(true)
                    Text(item.element.content)
                        .font(Type.hearsay)
                        .foregroundStyle(
                            item.element.status == .cancelled ? Palette.quiet : .secondary
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    nonisolated static func symbol(_ status: PlanStepStatus) -> String {
        switch status {
        case .pending: "circle.dashed"
        case .inProgress: "ellipsis"
        case .completed: "checkmark"
        case .cancelled: "xmark"
        }
    }

    /// A cancelled step is not a failed one — nothing went wrong, the agent
    /// changed its mind — so it stays greyscale. `refused` is not spent here at
    /// all, and `verified` only on a step that really finished.
    nonisolated static func tint(_ status: PlanStepStatus) -> Color {
        switch status {
        case .completed: Palette.verified
        case .pending, .inProgress, .cancelled: Palette.quiet
        }
    }

    /// The wire's word, said aloud: `in_progress` is a protocol token, not
    /// something to read out.
    nonisolated static func spoken(_ status: PlanStepStatus) -> String {
        status.rawValue.replacingOccurrences(of: "_", with: " ")
    }

    nonisolated static func spoken(_ steps: [PlanStep]) -> String {
        guard !steps.isEmpty else { return "no steps" }
        let lines = steps.map { "\($0.content) — \(spoken($0.status))" }
        return lines.joined(separator: "; ")
    }
}

// MARK: - Elliot's own words

/// The permission mode changed under the run.
///
/// ⚠️ **Elliot's sentence, not the agent's**, which is the whole reason this is
/// its own case. The fold's first draft turned a `.modeChanged` into an
/// `.agentText`, and that draws in `Type.hearsay` — a small lie about
/// authorship, inside the one app whose central claim is that it always says
/// whose words you are reading. The mode itself came off the wire, so it is a
/// fact and it is set as one.
private struct ModeChangedRow: View {
    var mode: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("Permission mode is now")
                .font(Type.prose)
                .foregroundStyle(.secondary)
            Fact(text: mode, tint: .primary)
        }
    }

    nonisolated static func sentence(_ mode: String) -> String {
        "Permission mode is now \(mode)."
    }
}

// MARK: - How the turn ended

/// The ACP counterpart of `TerminalRow`, keeping the same two tiers.
///
/// ⛔ **The split is not styling.** What the agent *said* is `Type.hearsay`;
/// the stop reason, the token counts and the refusals are what the protocol
/// *established* and they are set in the fact face. That is the app's whole
/// epistemology — `gh` is the fact, the agent's prose is a hint — so collapsing
/// the two would be a correctness defect wearing a cosmetic disguise.
/// Internal for the same reason as `TerminalRow`: `summary(_:)` is both drawn
/// and spoken.
struct TurnEndedRow: View {
    var summary: TurnSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Fact(
                text: Self.summary(summary),
                tint: summary.isClean ? Palette.verified : Palette.refused
            )
            if summary.truncationEvents > 0 {
                Fact(text: Self.truncation(summary.truncationEvents))
            }
            if let text = summary.text, !text.isEmpty {
                Text(text)
                    .font(Type.hearsay)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    /// Only the figures the summary carried. Every one of them is optional and
    /// a fabricated "0 tokens" would read as a measurement — the same reason
    /// `TerminalRow.summary` omits a turn count it was not given.
    ///
    /// An absent `costUSD` means nobody reported one, and absent is not zero: a
    /// turn that cost money and never said so must not be drawn as free.
    nonisolated static func summary(_ summary: TurnSummary) -> String {
        var parts = [summary.isClean ? "Finished clean" : "Finished with issues"]
        if let reason = summary.stopReason, !reason.isEmpty { parts.append(reason) }
        if let tokens = summary.inputTokens { parts.append("\(tokens) in") }
        if let tokens = summary.outputTokens { parts.append("\(tokens) out") }
        if let tokens = summary.totalTokens { parts.append("\(tokens) total") }
        if let usage = summary.usage {
            parts.append("\(usage.used)/\(usage.size) context")
            if let cost = usage.costUSD { parts.append(String(format: "$%.4f", cost)) }
        }
        if !summary.denials.isEmpty {
            parts.append(
                summary.denials.count == 1
                    ? "1 tool refused" : "\(summary.denials.count) tools refused"
            )
        }
        return parts.joined(separator: " · ")
    }

    /// ⚠️ **"events", not "lines", and the word is the whole point.**
    /// `LineBuffer.append` increments `droppedOversized` once per *chunk* for
    /// as long as `pending` stays over the cap, so one oversized line arriving
    /// in 64 KB reads reports hundreds — and the counter is read before the
    /// final drain, so it is a floor rather than a total. The only claim the
    /// figure supports is the binary one, and this sentence makes exactly that
    /// claim and no more.
    nonisolated static func truncation(_ events: Int) -> String {
        "\(events) truncation event(s) — this log is incomplete"
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
        // "Agent session" rather than "Session": the two cases coexist in one
        // archive, and a listener who hears the same word for both cannot tell
        // which decoder wrote the log being read.
        case .agentSession: "Agent session"
        case .thought: "It thought"
        case .toolCall: "Tool call"
        case .plan: "Plan"
        case .modeChanged: "Permission mode"
        case .turnEnded: "Turn"
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

        case .agentSession(let info):
            return "\(kind), \(AgentSessionRow.chips(info).joined(separator: ", "))"

        case .thought(let text):
            return "\(kind), \(text)"

        case .toolCall(let call):
            return "\(kind), \(ToolCallRow.spoken(call))"

        case .plan(let steps):
            return "\(kind), \(PlanRow.spoken(steps))"

        case .modeChanged(let mode):
            return "\(kind), \(ModeChangedRow.sentence(mode))"

        case .turnEnded(let summary):
            // The truncation warning is spoken as well as drawn: a listener
            // told a run finished clean, on a log that is missing lines, has
            // been told something the log cannot support.
            var sentence = "\(kind), \(TurnEndedRow.summary(summary))."
            if summary.truncationEvents > 0 {
                sentence += " \(TurnEndedRow.truncation(summary.truncationEvents))."
            }
            if let text = summary.text, !text.isEmpty { sentence += " \(text)" }
            return sentence
        }
    }

    /// A call still in flight has not failed. Saying "succeeded" for a missing
    /// result, or "failed" for one, would each be a claim the log cannot make.
    private static func spoken(_ outcome: ToolOutcome?) -> String {
        guard let outcome else { return "Still running." }
        return "\(outcome.isError ? "Failed" : "Succeeded"), \(outcome.preview)"
    }
}
