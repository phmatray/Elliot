import ElliotModel
import SwiftUI

/// One view per `IssueBlock` case.
///
/// The panel does not render an issue body as a wall of markdown; it renders it
/// as the components the body already is. Two rules from `DesignSystem.swift`
/// decide almost every choice in this file:
///
/// 1. **Monospace means a machine established it.** A code span, a code fence,
///    `#47`, `PR 72` and a repository path are set in the fact face. The
///    author's prose — a paragraph, a table cell, a criterion, the three
///    clauses of a user story — stays proportional. In particular the
///    `AS A / I WANT / SO THAT` captions are *Elliot's own* labelling of a
///    human's sentence: no machine established them, so they are proportional.
///
/// 2. **Colour is reserved for consequence.** Nothing here is a consequence —
///    an issue body is text someone typed — so nothing here spends a colour.
///    Every surface is `Surface.*` grey and every rule is `Surface.hairline`.
///    That is why there is no green tick on a done task; see `TaskListBlock`.
///
///    The one exception is syntax colour inside a **fenced** code block, which
///    the approved mockup carries and which `CodeFenceBlock` implements. It is
///    the one place in this file that spends an accent, it is bounded by the
///    fence's own `Surface.well` ground, and the reasoning — including what it
///    costs — is written out at `CodeTokenKind.tint`.
///
/// Every block is one combined accessibility element whose label leads with its
/// kind — `MarkdownAccessibility.label(for:)` is the whole of that decision, and
/// it is a pure function so a test can hold it.

// MARK: - Where a reference points

/// What an inline reference resolves to, which is only ever a repository.
///
/// A body's `#47` means "issue 47 **of this repository**" — the number carries
/// no repository of its own — so a card whose repo is unknown gets chips that
/// are drawn and inert rather than chips that guess at a URL.
struct MarkdownContext: Sendable, Hashable {
    var nameWithOwner: String?
    var defaultBranch: String

    init(nameWithOwner: String? = nil, defaultBranch: String = "main") {
        self.nameWithOwner = nameWithOwner
        self.defaultBranch = defaultBranch
    }

    init(repo: Repo?) {
        self.init(nameWithOwner: repo?.nameWithOwner, defaultBranch: repo?.defaultBranch ?? "main")
    }

    /// Nothing is linkable — used for a card whose repository has gone.
    static let unresolved = MarkdownContext()

    /// The URL a run opens, or `nil` when it opens nothing.
    ///
    /// A markdown link carries its own absolute URL and so resolves without a
    /// repository; the three reference kinds do not.
    func url(for run: InlineText.Run) -> String? {
        if case .link(_, let url) = run { return url }
        guard let nameWithOwner, !nameWithOwner.isEmpty else { return nil }
        switch run {
        case .issueRef(let number):
            // `/issues/<n>` redirects to the pull request when the number is
            // one, which is exactly what a bare `#47` should do.
            return "https://github.com/\(nameWithOwner)/issues/\(number)"
        case .prRef(let number):
            return "https://github.com/\(nameWithOwner)/pull/\(number)"
        case .path(let path):
            return "https://github.com/\(nameWithOwner)/blob/\(defaultBranch)/\(path)"
        case .text, .emphasis, .strong, .code, .link:
            return nil
        }
    }
}

// MARK: - A run of blocks

struct MarkdownBlockList: View {
    var blocks: [IssueBlock]
    var context: MarkdownContext

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // By offset, not by the block itself: two identical paragraphs in
            // one body are two blocks, and `IssueBlock`'s `Hashable` would
            // collapse them into one row.
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, context: context)
            }
        }
    }
}

// MARK: - One block

struct MarkdownBlockView: View {
    var block: IssueBlock
    var context: MarkdownContext

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(MarkdownAccessibility.label(for: block))
    }

    @ViewBuilder
    private var content: some View {
        switch block {
        case .heading(let level, let text):
            HeadingBlock(level: level, text: text)

        case .paragraph(let text):
            InlineTextView(text: text, context: context, font: Type.bodyProse)

        case .userStory(let role, let want, let benefit):
            UserStoryBlock(role: role, want: want, benefit: benefit)

        case .orderedList(let items):
            OrderedListBlock(items: items, context: context)

        case .bulletList(let items):
            BulletListBlock(items: items, context: context)

        case .taskList(let items):
            TaskListBlock(items: items, context: context)

        case .codeFence(let language, let code):
            CodeFenceBlock(language: language, code: code)

        case .callout(let kind, let body):
            CalloutBlock(kind: kind, blocks: body, context: context)

        case .quote(let body):
            QuoteBlock(blocks: body, context: context)

        case .table(let header, let rows):
            TableBlock(header: header, rows: rows, context: context)

        case .collapsible(let summary, let body, let lineCount):
            CollapsibleBlock(summary: summary, blocks: body, lineCount: lineCount, context: context)

        case .rule:
            Rectangle()
                .fill(Surface.hairline)
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }
}

// MARK: - Heading

/// A body's own headings become the pane's section captions, which is what a
/// reader is already using them as. Below level 2 they are row titles instead:
/// four nested console labels read as four sections rather than one with three
/// sub-parts.
private struct HeadingBlock: View {
    var level: Int
    var text: InlineText

    var body: some View {
        if level <= 2 {
            ConsoleLabel(text: text.plain)
                .padding(.top, 4)
        } else {
            Text(text.plain)
                .font(Type.rowTitle)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - User story

/// `AS A / I WANT / SO THAT`, captioned.
///
/// The captions are set in `Type.labelSmall` — **proportional**, not the fact
/// face. They are Elliot's labelling of a sentence a human wrote; no machine
/// established them, and setting them in monospace would claim otherwise.
private struct UserStoryBlock: View {
    var role: String
    var want: String
    var benefit: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Rectangle()
                .fill(Surface.chipFillHover)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 3) {
                clause("As a", role)
                clause("I want", want)
                clause("So that", benefit)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// An empty clause is left out rather than captioned: a story can be
    /// half-written, and "SO THAT" over nothing reads as a missing render.
    @ViewBuilder
    private func clause(_ caption: String, _ text: String) -> some View {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(caption.uppercased())
                    .font(Type.labelSmall)
                    .tracking(0.6)
                    .foregroundStyle(Palette.quiet)
                Text(text)
                    .font(Type.bodyProse)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Lists

/// The acceptance criteria, usually. Numbered from 1 in source order — the
/// ordinal is how a criterion is referred to in conversation, so it is printed
/// rather than drawn as a bullet.
private struct OrderedListBlock: View {
    var items: [InlineText]
    var context: MarkdownContext

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    // The ordinal is the app counting, not the author writing,
                    // so it is set in the fact face.
                    Fact(text: "\(index + 1)", tint: Palette.quiet, small: true)
                        .frame(width: 16, alignment: .trailing)
                    InlineTextView(text: item, context: context, font: Type.prose)
                }
            }
        }
    }
}

private struct BulletListBlock: View {
    var items: [InlineText]
    var context: MarkdownContext

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("•")
                        .font(Type.prose)
                        .foregroundStyle(Palette.quiet)
                        .frame(width: 16, alignment: .trailing)
                        .accessibilityHidden(true)
                    InlineTextView(text: item, context: context, font: Type.prose)
                }
            }
        }
    }
}

// MARK: - Task list

/// `- [x]` / `- [ ]` — the checklist `implement-issue` ticks as it works, with
/// a meter over it.
///
/// The meter counts **this list's** boxes rather than the document's, so the
/// number beside a list is always the number of ticks in it.
///
/// Greyscale, including the ticked box, and that is not a shortcut: a ticked
/// box is the agent's own claim written into an issue body. `gh` established
/// nothing about it. Filling it with `Palette.verified` would let arbitrary
/// prose imitate a receipt — the same reason `IssueBlock.callout` is documented
/// as rendering greyscale.
/// Internal rather than `private` only so `IssuePaneTests` can reach `meter(_:)`
/// — the meter is the one thing here with a number in it, and a number nothing
/// checks is a number that drifts.
struct TaskListBlock: View {
    var items: [TaskItem]
    var context: MarkdownContext

    /// The whole meter, derived. Pure — including the counting, not just the
    /// formatting — so "the count equals the ticked boxes" is a claim a test
    /// can hold rather than one only an eye can check.
    nonisolated static func meter(_ items: [TaskItem]) -> (done: Int, total: Int, text: String) {
        let done = items.filter(\.done).count
        return (done, items.count, "\(done) / \(items.count)")
    }

    var body: some View {
        let meter = Self.meter(items)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView(value: Double(meter.done), total: Double(max(1, meter.total)))
                    .progressViewStyle(.linear)
                    .tint(.secondary)
                    .frame(maxWidth: 140)
                    .accessibilityHidden(true)
                Fact(text: meter.text, tint: Palette.quiet, small: true)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    if index > 0 {
                        Rectangle().fill(Surface.hairline).frame(height: 1)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: item.done ? "checkmark.square" : "square")
                            .font(Type.prose)
                            .foregroundStyle(item.done ? Palette.quiet : .secondary)
                            .accessibilityHidden(true)
                        InlineTextView(text: item.text, context: context, font: Type.prose)
                            .foregroundStyle(item.done ? Palette.quiet : .primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

// MARK: - Code fence

/// The three token kinds the approved mockup colours, mapped onto the palette.
///
/// The mapping is the mockup's, verbatim: its line 307 reads
/// `.md-code .k{color:var(--armed)} .md-code .s{color:var(--verified)}
/// .md-code .c{color:var(--text-3)}` — keyword is `armed`, string is
/// `verified`, comment is the quiet greyscale tier.
///
/// ⚠️ **This spends two consequence accents on syntax, and that is a real
/// cost, not a technicality.** `DesignSystem.swift` reserves colour for
/// consequence: `armed` means *a gesture here starts an autonomous run*. A
/// keyword drawn in it means nothing of the sort. The mockup does it and it was
/// approved, so it ships — but it is scoped so the two readings cannot be
/// confused:
///
/// - it exists **only inside a fence**, on the fence's own `Surface.well`
///   ground and inside its hairline border, so a coloured token always sits on
///   a surface that says "this whole region is machine output";
/// - it never reaches an inline code span or a word of prose — `InlineRow`
///   renders those and does not call the highlighter;
/// - nothing coloured here is interactive, so no `armed` token here is ever
///   next to a gesture that could be mistaken for arming one;
/// - it adds **no sixth accent**. `BrandColor.consequences` still lists five,
///   and `BrandColorTests` still holds that. This borrows two of them inside
///   one bounded surface rather than minting anything.
///
/// If the fence ever grows a button, or syntax colour ever escapes the well,
/// this is the trade that has been broken and this comment is the record of
/// what was traded.
private extension CodeTokenKind {
    var tint: Color {
        switch self {
        case .keyword: Palette.armed
        case .string: Palette.verified
        case .comment: Palette.quiet
        case .plain: .primary
        }
    }
}

/// Machine text on the machine ground.
///
/// Syntax colour comes from `CodeHighlighter`, which lives in `ElliotModel` so
/// the cues that decide what a keyword *is* are pure and unit-tested rather
/// than written inside a SwiftUI body where nothing can hold them. This view
/// only maps the kinds it is handed onto the palette — see the ⚠️ on
/// `CodeTokenKind.tint` for what that mapping costs.
///
/// Soft-wrapped rather than horizontally scrollable: the panel is narrow, and a
/// line you have to scroll sideways to finish is a line nobody finishes.
private struct CodeFenceBlock: View {
    var language: String?
    var code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // No bar at all when the author gave no info string. A chip reading
            // "text" would be Elliot claiming a language nobody wrote.
            if let language, !language.isEmpty {
                HStack(spacing: 6) {
                    MonoChip(text: language)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Surface.hairline).frame(height: 1)
                }
            }

            highlighted
                .font(Type.log)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .background(Surface.well)
        .clipShape(RoundedRectangle(cornerRadius: Metric.nestedRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.nestedRadius)
                .strokeBorder(Surface.hairline, lineWidth: 1)
        }
    }

    /// The fence as one `Text`, built by concatenating a segment per token.
    ///
    /// `Text(verbatim:)` at every segment, never `Text(_:)`: the latter takes a
    /// `LocalizedStringKey`, so a fence containing `%d` or `%@` would be run
    /// through string formatting and a fence containing an issue number could
    /// be re-formatted for the reader's locale. This is source code — it is
    /// shown exactly as the author wrote it or it is worthless.
    ///
    /// No `.foregroundStyle` on the whole run: each segment carries its own,
    /// and `.plain` carries `.primary`, so nothing here falls through to a
    /// colour it did not choose.
    ///
    /// The fence's own `language` is handed over, which is the *declaration*
    /// the author wrote in the info string and the same string the chip above
    /// displays — never a guess made from the content. A fence with no info
    /// string, or one naming a language the highlighter has no rules for, is
    /// tokenised by the language-agnostic cues exactly as before.
    private var highlighted: Text {
        CodeHighlighter.tokens(of: code, language: language).reduce(Text(verbatim: "")) { text, token in
            text + Text(verbatim: token.text).foregroundStyle(token.kind.tint)
        }
    }
}

/// A short machine token on a chip ground — a fence's language, a run's model
/// and permission mode, a tool's name. Not a `LinkBadge`: that is a *fact that
/// is also a link*, a real button that is disabled when it has no URL, and none
/// of these is.
///
/// Internal rather than private because `LogRows.swift` draws the same thing:
/// a second copy would drift in padding and face, and the two panes sit one
/// tab apart.
struct MonoChip: View {
    var text: String

    var body: some View {
        Text(text)
            .font(Type.factSmall)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Surface.chipFill)
            .clipShape(Capsule())
    }
}

// MARK: - Callout and quote

/// `> [!IMPORTANT]`, in greyscale, with the kind as a `ConsoleLabel`.
///
/// The tint is not an oversight: letting an issue author's callout paint the
/// panel amber would let arbitrary prose imitate a run state, which is the one
/// thing the colour rule exists to prevent. `IssueBlock.callout` says so at the
/// model layer; this is where it is honoured.
private struct CalloutBlock: View {
    var kind: String
    var blocks: [IssueBlock]
    var context: MarkdownContext

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(Surface.chipFillHover)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 4) {
                ConsoleLabel(text: kind)
                MarkdownBlockList(blocks: blocks, context: context)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.recess)
        .clipShape(RoundedRectangle(cornerRadius: Metric.nestedRadius))
    }
}

private struct QuoteBlock: View {
    var blocks: [IssueBlock]
    var context: MarkdownContext

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Rectangle()
                .fill(Surface.chipFill)
                .frame(width: 2)
            MarkdownBlockList(blocks: blocks, context: context)
        }
    }
}

// MARK: - Table

/// Rules between the rows, prose in the cells.
///
/// The cells are **not** monospaced: a table in an issue body holds whatever
/// the author put in it, and setting all of it in the fact face would claim a
/// machine produced every cell. The runs inside a cell still decide for
/// themselves — a `` `swift test` `` span is mono because it is a code span.
private struct TableBlock: View {
    var header: [InlineText]
    var rows: [[InlineText]]
    var context: MarkdownContext

    private var columnCount: Int {
        max(header.count, rows.map(\.count).max() ?? 0)
    }

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                    Text(cell.plain.uppercased())
                        .font(Type.labelSmall)
                        .tracking(0.6)
                        .foregroundStyle(Palette.quiet)
                        .padding(.vertical, 4)
                }
            }
            rule
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        InlineTextView(text: cell, context: context, font: Type.prose)
                            .padding(.vertical, 4)
                    }
                }
                if index < rows.count - 1 { rule }
            }
        }
    }

    private var rule: some View {
        Rectangle()
            .fill(Surface.hairline)
            .frame(height: 1)
            .gridCellUnsizedAxes(.horizontal)
            .gridCellColumns(columnCount)
    }
}

// MARK: - Collapsible

/// `<details>`, which actually opens.
///
/// Closed on arrival and closed again on the next card: `@State` on a view
/// rebuilt per selection is the whole of that, and it is the behaviour GitHub
/// has. `lineCount` is what the summary row reports before it is opened — the
/// only honest answer to "how much is under here" without opening it.
private struct CollapsibleBlock: View {
    var summary: InlineText
    var blocks: [IssueBlock]
    var lineCount: Int
    var context: MarkdownContext

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            MarkdownBlockList(blocks: blocks, context: context)
                .padding(.top, 6)
                .padding(.leading, 2)
        } label: {
            HStack(spacing: 7) {
                Text(summary.plain)
                    .font(Type.bodyProse)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Fact(text: "\(lineCount) lines", tint: Palette.quiet, small: true)
            }
            .contentShape(Rectangle())
        }
        .padding(8)
        .background(Surface.recessFaint)
        .clipShape(RoundedRectangle(cornerRadius: Metric.nestedRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.nestedRadius)
                .strokeBorder(Surface.hairline, lineWidth: 1)
        }
    }
}

// MARK: - Inline runs

/// A line of inline content: text, emphasis, code spans, and the references
/// that are chips.
///
/// Two renderings, and the split is about cost rather than taste. A line with
/// nothing to click is **one** `Text`, which wraps the way `Text` wraps and
/// costs one view. A line carrying a chip cannot be one `Text` — a button is
/// not a run — so it is laid out by `InlineFlow` over one subview per word,
/// which is what makes a chip sit *in* the sentence instead of beside the
/// paragraph. This repository's own issue bodies run to hundreds of lines;
/// word-splitting all of them would be thousands of views for the handful that
/// need it.
struct InlineTextView: View {
    var text: InlineText
    var context: MarkdownContext
    var font: Font = Type.bodyProse

    var body: some View {
        if InlineTextView.isFlowing(text) {
            InlineFlow {
                ForEach(Array(flowItems.enumerated()), id: \.offset) { _, item in
                    item.view(font: font)
                }
            }
        } else {
            InlineTextView.concatenated(text, font: font)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    /// The atoms the flow places — pieces, with the punctuation that was
    /// written flush against one carried inside its item rather than beside it.
    private var flowItems: [InlineItem] {
        InlineTextView.items(InlineTextView.pieces(of: text, context: context))
    }

    /// True when the line holds something clickable, which is the only reason
    /// to pay for the flow layout.
    ///
    /// `nonisolated`, and so are the three below it, because `View` is a
    /// `@preconcurrency @MainActor` protocol: a static member of a conforming
    /// type is inferred main-actor-isolated, and `@preconcurrency` downgrades
    /// calling it from anywhere else to *nothing at compile time* and a
    /// `SIGTRAP` at run time. These are pure functions over value types — no
    /// view, no environment — and a test calls them off the main actor.
    nonisolated static func isFlowing(_ text: InlineText) -> Bool {
        text.runs.contains { run in
            switch run {
            case .issueRef, .prRef, .path, .link: return true
            case .text, .emphasis, .strong, .code: return false
            }
        }
    }

    /// The whole line as one `Text`, per-run faces preserved by concatenation.
    ///
    /// A code span gets the fact face and **no chip ground**. `Text` cannot
    /// carry a background per run, so a ground here would exist on the flowing
    /// path and vanish on this one — and the face already says what the ground
    /// would have: this came from a machine.
    nonisolated static func concatenated(_ text: InlineText, font: Font) -> Text {
        text.runs.reduce(Text(verbatim: "")) { accumulated, run in
            switch run {
            case .text(let value):
                return accumulated + Text(value).font(font)
            case .emphasis(let value):
                return accumulated + Text(value).font(font.italic())
            case .strong(let value):
                return accumulated + Text(value).font(font.bold())
            case .code(let value):
                return accumulated + Text(value).font(Type.fact)
            // Unreachable: a line holding any of these is laid out by
            // `InlineFlow`. Rendered as plain text rather than dropped, because
            // a run that vanishes is the failure mode nothing reports.
            case .issueRef, .prRef, .path, .link:
                return accumulated + Text(InlineText(runs: [run]).plain).font(font)
            }
        }
    }

    /// The line broken into the atoms the flow layout places.
    ///
    /// Words, because a flow layout wraps between subviews and a whole sentence
    /// as one subview would wrap inside itself — putting the chip after it
    /// beside a three-line block instead of after the last word. Code spans and
    /// chips stay whole: a split code span would draw as two.
    ///
    /// One kind of word is not a word: punctuation that opens a run written
    /// **flush** against the run before it — the comma in `#79, and`. It was an
    /// atom of its own until #79, which is to say the flow could wrap between
    /// the chip and the comma, stranding the comma at the start of the next
    /// line, and put 4pt of spacing there when it did not. It comes out as
    /// `.glued`, and `items(_:)` folds it into the atom it belongs to.
    ///
    /// ⚠️ **Punctuation only, and only when flush.** Drop the first restriction
    /// and a letter flush against a chip (`a/b.swift*really*`) is glued instead
    /// of read as a word — `emphasisSurvivesTheSplit` goes red on exactly that,
    /// which is how the restriction was found. Drop the second and a comma
    /// opening a run whose predecessor *ended* in a space is dragged back onto
    /// the word before it; nothing in the suite covers that one, which is why
    /// it is written down here.
    nonisolated static func pieces(of text: InlineText, context: MarkdownContext) -> [InlinePiece] {
        var out: [InlinePiece] = []
        // Whether what came before ends flush against whatever follows it. A
        // chip or a code span always does — neither carries a space of its own
        // — and a prose run does when its last character is not one.
        var flush = false

        func prose(_ value: String, _ style: InlinePiece.WordStyle) {
            guard !value.isEmpty else { return }
            var rest = value[...]
            if flush, !out.isEmpty {
                let tail = rest.prefix { trailingPunctuation.contains($0) }
                if !tail.isEmpty {
                    out.append(.glued(String(tail), style))
                    rest = rest.dropFirst(tail.count)
                }
            }
            out += words(rest).map { .word($0, style) }
            flush = !(value.last?.isWhitespace ?? true)
        }

        for run in text.runs {
            switch run {
            case .text(let value):
                prose(value, .plain)
            case .emphasis(let value):
                prose(value, .emphasis)
            case .strong(let value):
                prose(value, .strong)
            case .code(let value):
                out.append(.code(value))
                flush = true
            case .issueRef(let number):
                out.append(
                    .chip(text: "#\(number)", symbol: "circle.dashed", url: context.url(for: run))
                )
                flush = true
            case .prRef(let number):
                out.append(
                    .chip(
                        text: "PR \(number)", symbol: "arrow.triangle.pull",
                        url: context.url(for: run)
                    )
                )
                flush = true
            case .path(let path):
                out.append(.chip(text: path, symbol: "doc.text", url: context.url(for: run)))
                flush = true
            case .link(let label, let url):
                // Proportional, not a chip: a link's text is the author's
                // prose, and the fact face would claim a machine wrote it.
                out += words(label[...]).map { .link($0, url: url) }
                flush = !(label.last?.isWhitespace ?? true)
            }
        }
        return out
    }

    /// The pieces regrouped into what the flow is allowed to break between.
    ///
    /// A `.glued` fragment joins the item before it, so the two are one subview
    /// and the layout cannot separate them. A fragment with nothing before it
    /// becomes an ordinary word rather than disappearing — the whole file is
    /// written against runs that vanish.
    nonisolated static func items(_ pieces: [InlinePiece]) -> [InlineItem] {
        var out: [InlineItem] = []
        for piece in pieces {
            switch piece {
            case .glued(let value, let style) where out.isEmpty:
                out.append(InlineItem(piece: .word(value, style)))
            case .glued:
                out[out.count - 1].glued.append(piece)
            default:
                out.append(InlineItem(piece: piece))
            }
        }
        return out
    }

    /// What belongs to whatever it follows. A list rather than
    /// `CharacterSet.punctuationCharacters`: an em dash and an opening bracket
    /// are punctuation too, and neither trails anything.
    nonisolated static let trailingPunctuation: Set<Character> = [
        ",", ".", ";", ":", "!", "?", ")", "]", "}", "'", "\"", "’", "”", "…",
    ]

    nonisolated private static func words(_ value: Substring) -> [String] {
        value.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    }
}

/// One atom of flowing inline content.
enum InlinePiece: Hashable, Sendable {
    case word(String, WordStyle)
    case code(String)
    case chip(text: String, symbol: String, url: String?)
    case link(String, url: String)
    /// Punctuation written flush against the piece before it, with the style of
    /// the run it came from. Drawn exactly like a word; it exists so
    /// `InlineTextView.items(_:)` can tell the two apart.
    case glued(String, WordStyle)

    enum WordStyle: Hashable, Sendable {
        case plain, emphasis, strong
    }

    /// `@MainActor` because a button style is: the only caller is a `body`.
    @MainActor
    @ViewBuilder
    func view(font: Font) -> some View {
        switch self {
        case .word(let value, let style), .glued(let value, let style):
            Text(value)
                .font(style.font(from: font))
        case .code(let value):
            Text(value)
                .font(Type.fact)
        case .chip(let text, let symbol, let url):
            LinkBadge(text: text, systemImage: symbol, url: url)
        case .link(let value, let url):
            Button {
                guard let real = URL(string: url) else { return }
                NSWorkspace.shared.open(real)
            } label: {
                Text(value)
                    .font(font)
                    .underline()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(url)
        }
    }
}

extension InlinePiece.WordStyle {
    func font(from base: Font) -> Font {
        switch self {
        case .plain: base
        case .emphasis: base.italic()
        case .strong: base.bold()
        }
    }
}

/// One subview of the flow: a piece, plus anything written flush against its
/// right side.
///
/// The flow wraps *between* subviews, so this is the unit that says what may
/// not come apart. `glued` is empty for all but a handful of items on a line —
/// hence the two rendering paths, the same cost decision `isFlowing` makes one
/// level up.
struct InlineItem: Hashable, Sendable {
    var piece: InlinePiece
    var glued: [InlinePiece] = []

    /// `@MainActor` for the same reason `InlinePiece.view(font:)` is.
    @MainActor
    @ViewBuilder
    func view(font: Font) -> some View {
        if glued.isEmpty {
            piece.view(font: font)
        } else {
            // Zero spacing and a shared baseline: this is one word as far as
            // the reader is concerned, and a chip's capsule sits on the same
            // line as the comma after it.
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                piece.view(font: font)
                ForEach(Array(glued.enumerated()), id: \.offset) { _, fragment in
                    fragment.view(font: font)
                }
            }
        }
    }
}

// MARK: - The flow

/// Left-to-right, wrapping at the proposed width.
///
/// SwiftUI has no flowing stack, and this is the smallest one that does the
/// job: no cache, no alignment guides, no priorities. The line breaking is
/// `rows(widths:maxWidth:spacing:)` — pure arithmetic over widths, so the one
/// part of this file that could be wrong in an arithmetic rather than a visual
/// way is the part a test can hold.
struct InlineFlow: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 3

    /// Contiguous ranges of subviews, one per line.
    ///
    /// A subview wider than the whole line still gets a line of its own rather
    /// than being dropped — hence the `index > start` guard, which also makes
    /// the function total for an empty input.
    static func rows(widths: [CGFloat], maxWidth: CGFloat, spacing: CGFloat) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = 0
        var used: CGFloat = 0

        for (index, width) in widths.enumerated() {
            if index > start, used + spacing + width > maxWidth {
                out.append(start..<index)
                start = index
                used = width
            } else {
                used += index == start ? width : spacing + width
            }
        }
        if start < widths.count { out.append(start..<widths.count) }
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        guard !sizes.isEmpty else { return .zero }

        let limit = proposal.width ?? .infinity
        let rows = Self.rows(widths: sizes.map(\.width), maxWidth: limit, spacing: spacing)

        let height = rows.reduce(CGFloat.zero) { total, row in
            total + (sizes[row].map(\.height).max() ?? 0)
        } + lineSpacing * CGFloat(max(0, rows.count - 1))

        let widest = rows.reduce(CGFloat.zero) { widest, row in
            max(widest, Self.lineWidth(sizes[row].map(\.width), spacing: spacing))
        }
        return CGSize(width: limit.isFinite ? min(widest, limit) : widest, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        guard !sizes.isEmpty else { return }

        let rows = Self.rows(widths: sizes.map(\.width), maxWidth: bounds.width, spacing: spacing)
        var y = bounds.minY

        for row in rows {
            let lineHeight = sizes[row].map(\.height).max() ?? 0
            var x = bounds.minX
            for index in row {
                subviews[index].place(
                    at: CGPoint(x: x, y: y + lineHeight / 2),
                    anchor: .leading,
                    proposal: ProposedViewSize(sizes[index])
                )
                x += sizes[index].width + spacing
            }
            y += lineHeight + lineSpacing
        }
    }

    private static func lineWidth(_ widths: some Collection<CGFloat>, spacing: CGFloat) -> CGFloat {
        widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1))
    }
}

// MARK: - What a screen reader hears

/// One label per block, leading with the block's kind.
///
/// Pure and in one place because the rule — *every block is one combined
/// element whose label leads with its kind* — is a rule, and a rule written
/// twelve times inside twelve `body`s is a rule nothing can check.
enum MarkdownAccessibility {

    /// The word a block's label starts with.
    static func kind(of block: IssueBlock) -> String {
        switch block {
        case .heading: "Heading"
        case .paragraph: "Paragraph"
        case .userStory: "User story"
        case .orderedList: "Numbered list"
        case .bulletList: "List"
        case .taskList: "Task list"
        case .codeFence: "Code"
        case .callout: "Callout"
        case .quote: "Quote"
        case .table: "Table"
        case .collapsible: "Collapsible"
        case .rule: "Separator"
        }
    }

    static func label(for block: IssueBlock) -> String {
        let kind = kind(of: block)
        switch block {
        case .heading(let level, let text):
            return "\(kind) \(level). \(text.plain)"

        case .paragraph(let text):
            return "\(kind). \(text.plain)"

        case .userStory(let role, let want, let benefit):
            var parts = ["\(kind)."]
            if !role.isEmpty { parts.append("As a \(role).") }
            if !want.isEmpty { parts.append("I want \(want).") }
            if !benefit.isEmpty { parts.append("So that \(benefit).") }
            return parts.joined(separator: " ")

        case .orderedList(let items):
            let spoken = items.enumerated()
                .map { "\($0.offset + 1). \($0.element.plain)" }
                .joined(separator: " ")
            return "\(kind), \(items.count) items. \(spoken)"

        case .bulletList(let items):
            return "\(kind), \(items.count) items. " + items.map(\.plain).joined(separator: ". ")

        case .taskList(let items):
            let done = items.filter(\.done).count
            let spoken = items
                .map { "\($0.done ? "done" : "not done"), \($0.text.plain)" }
                .joined(separator: ". ")
            return "\(kind), \(done) of \(items.count) done. \(spoken)"

        case .codeFence(let language, let code):
            let named = language.map { " in \($0)" } ?? ""
            return "\(kind) block\(named). \(code)"

        case .callout(let calloutKind, let body):
            return "\(kind), \(calloutKind.lowercased()). " + spoken(body)

        case .quote(let body):
            return "\(kind). " + spoken(body)

        case .table(let header, let rows):
            let columns = header.map(\.plain).joined(separator: ", ")
            return "\(kind), \(rows.count) rows. Columns: \(columns). "
                + rows.map { $0.map(\.plain).joined(separator: ", ") }.joined(separator: ". ")

        case .collapsible(let summary, _, let lineCount):
            return "\(kind). \(summary.plain), \(lineCount) lines hidden."

        case .rule:
            return kind
        }
    }

    private static func spoken(_ blocks: [IssueBlock]) -> String {
        blocks.map(label(for:)).joined(separator: " ")
    }
}
