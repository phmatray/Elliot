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
///    That is why there is no syntax highlighting in a code fence and no green
///    tick on a done task; see `CodeFenceBlock` and `TaskListBlock`.
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

/// Machine text on the machine ground.
///
/// **No syntax colour, deliberately.** Highlighting would spend three or four
/// hues on keywords and strings, and the app's second rule reserves colour for
/// consequence: `armed` means a gesture starts an agent, `irreversible` means it
/// merges. A palette that also paints YAML keys stops being readable as either.
/// The fence is already legible as machine output through `Surface.well` and the
/// fact face — that is the whole job the colour would have been doing.
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

            Text(code)
                .font(Type.log)
                .foregroundStyle(.primary)
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
}

/// A short machine token on a chip ground — a fence's language, and nothing
/// else so far. Not a `LinkBadge`: that is a *fact that is also a link*, a real
/// button that is disabled when it has no URL, and a language name is neither.
private struct MonoChip: View {
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
                ForEach(Array(InlineTextView.pieces(of: text, context: context).enumerated()), id: \.offset) { _, piece in
                    piece.view(font: font)
                }
            }
        } else {
            InlineTextView.concatenated(text, font: font)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
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
    nonisolated static func pieces(of text: InlineText, context: MarkdownContext) -> [InlinePiece] {
        text.runs.flatMap { run -> [InlinePiece] in
            switch run {
            case .text(let value):
                return words(value).map { .word($0, .plain) }
            case .emphasis(let value):
                return words(value).map { .word($0, .emphasis) }
            case .strong(let value):
                return words(value).map { .word($0, .strong) }
            case .code(let value):
                return [.code(value)]
            case .issueRef(let number):
                return [.chip(text: "#\(number)", symbol: "circle.dashed", url: context.url(for: run))]
            case .prRef(let number):
                return [.chip(text: "PR \(number)", symbol: "arrow.triangle.pull", url: context.url(for: run))]
            case .path(let path):
                return [.chip(text: path, symbol: "doc.text", url: context.url(for: run))]
            case .link(let label, let url):
                // Proportional, not a chip: a link's text is the author's
                // prose, and the fact face would claim a machine wrote it.
                return words(label).map { .link($0, url: url) }
            }
        }
    }

    nonisolated private static func words(_ value: String) -> [String] {
        value.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    }
}

/// One atom of flowing inline content.
enum InlinePiece: Hashable, Sendable {
    case word(String, WordStyle)
    case code(String)
    case chip(text: String, symbol: String, url: String?)
    case link(String, url: String)

    enum WordStyle: Hashable, Sendable {
        case plain, emphasis, strong
    }

    /// `@MainActor` because a button style is: the only caller is a `body`.
    @MainActor
    @ViewBuilder
    func view(font: Font) -> some View {
        switch self {
        case .word(let value, let style):
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
