import ElliotModel
import Foundation
import SwiftUI
import Testing

@testable import ElliotAppKit

/// What a test can hold of the issue pane.
///
/// Not the pixels. `swift test` cannot see where a chip sits in a sentence or
/// whether a fence wrapped, and this project has paid for pretending otherwise
/// three times over (#47, #50, #52, #53). So nothing here asserts a position.
///
/// What it asserts is everything in the pane that is a *decision* rather than
/// an appearance: which sections a card yields, where a reference points, what
/// a screen reader is told, how a line is broken, and the one number on screen
/// — the task meter — that could silently stop matching its boxes.
@Suite("Issue pane")
struct IssuePaneTests {

    // MARK: - Fixtures

    /// Fixtures live at the repository root, not in a resource bundle: the same
    /// files are opened by hand when reproducing a body that rendered badly.
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ElliotAppKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // ElliotKit
        .deletingLastPathComponent()   // repo root

    private static func issueFixture(_ name: String) -> String {
        (try? String(
            contentsOf: repoRoot.appendingPathComponent("Fixtures/issues/\(name)"),
            encoding: .utf8
        )) ?? ""
    }

    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    private func card(story: UserStory? = nil, body: String = "", issue: Int? = nil) -> Card {
        Card(
            repoID: UUID(), title: "Subject", body: body, story: story,
            issueNumber: issue,
            columnEnteredAt: epoch, createdAt: epoch, updatedAt: epoch
        )
    }

    private let story = UserStory(
        role: "maintainer",
        want: "every pull request built by something other than my laptop",
        benefit: "a green tick means the same thing on Monday as on Friday",
        acceptanceCriteria: ["A workflow runs on pull_request", "A failing test fails the job"]
    )

    private func document(_ body: String) -> IssueDocument {
        IssueMarkdownParser.parse(body)
    }

    // MARK: - Both, not either

    /// The bug this pane exists to fix. `InspectorView` joined the two sections
    /// with an `else if`, so a card carrying a locally-typed story **and** an
    /// imported issue body drew only the story — no error, no empty region,
    /// just half the card silently missing.
    @Test("A card with both a story and a body yields both sections, in that order")
    func storyAndBodyBothRender() {
        let subject = card(story: story, body: "## Problem\n\nNothing runs on a pull request.\n", issue: 47)
        let parsed = document(subject.body)

        let sections = IssuePane.sections(for: subject, document: parsed)

        #expect(sections.count == 2, "One of the two was dropped — the `else if` is back.")
        #expect(sections.first == .story(story))
        #expect(sections.last == .body(parsed.blocks))
    }

    @Test("A story with no body yields only the story")
    func storyAlone() {
        let subject = card(story: story)
        #expect(IssuePane.sections(for: subject, document: document("")) == [.story(story)])
    }

    @Test("A body with no story yields only the body")
    func bodyAlone() {
        let subject = card(body: "A plain note.", issue: nil)
        let parsed = document("A plain note.")
        #expect(IssuePane.sections(for: subject, document: parsed) == [.body(parsed.blocks)])
    }

    /// A section that exists but draws nothing is the empty render the value
    /// type is here to prevent, so an empty card yields no sections at all.
    @Test("A card with neither yields nothing, and whitespace is not a body")
    func neither() {
        #expect(IssuePane.sections(for: card(), document: document("")).isEmpty)
        #expect(IssuePane.sections(for: card(body: "   \n\n  "), document: document("   \n\n  ")).isEmpty)
    }

    /// A half-written story has no narrative to show, so it is not a section.
    /// `CardFieldsEditor` can leave it in that state.
    @Test("An empty story is not a section")
    func emptyStoryIsNotASection() {
        let blank = UserStory(role: "", want: "", benefit: "")
        #expect(IssuePane.sections(for: card(story: blank), document: document("")).isEmpty)
    }

    // MARK: - Where a chip points

    @Test("A reference resolves against the card's repository")
    func referencesResolve() {
        let context = MarkdownContext(nameWithOwner: "phmatray/Elliot", defaultBranch: "main")

        #expect(context.url(for: .issueRef(47)) == "https://github.com/phmatray/Elliot/issues/47")
        #expect(context.url(for: .prRef(72)) == "https://github.com/phmatray/Elliot/pull/72")
        #expect(
            context.url(for: .path(".github/workflows/ci.yml"))
                == "https://github.com/phmatray/Elliot/blob/main/.github/workflows/ci.yml"
        )
    }

    /// The branch is the repository's, not `main` assumed: 212 of the repos
    /// this app is pointed at default to `dev`, and a blob URL on the wrong
    /// branch is a 404 rather than a visible mistake.
    @Test("A path chip follows the repository's own default branch")
    func pathFollowsDefaultBranch() {
        let context = MarkdownContext(repo: Repo(
            path: "/tmp/AtypWebsite", nameWithOwner: "phmatray/AtypWebsite",
            defaultBranch: "dev", displayName: "AtypWebsite"
        ))
        #expect(context.url(for: .path("Atypical/Program.cs"))
            == "https://github.com/phmatray/AtypWebsite/blob/dev/Atypical/Program.cs")
    }

    /// `#47` means "issue 47 of *this* repository" — the number carries no
    /// repository of its own. With none known the chip must be inert rather
    /// than guess, which is the same rule the app applies to everything else it
    /// has not established.
    @Test("With no repository, a reference opens nothing")
    func unresolvedReferencesOpenNothing() {
        let context = MarkdownContext.unresolved
        #expect(context.url(for: .issueRef(47)) == nil)
        #expect(context.url(for: .prRef(72)) == nil)
        #expect(context.url(for: .path("a/b.swift")) == nil)
        #expect(MarkdownContext(repo: nil).url(for: .issueRef(47)) == nil)
    }

    /// A markdown link carries its own absolute URL, so it resolves with or
    /// without a repository.
    @Test("A markdown link keeps its own URL")
    func linksKeepTheirURL() {
        let run = InlineText.Run.link(text: "the spec", url: "https://example.org/spec")
        #expect(MarkdownContext.unresolved.url(for: run) == "https://example.org/spec")
        #expect(MarkdownContext(nameWithOwner: "phmatray/Elliot").url(for: run) == "https://example.org/spec")
    }

    @Test("Prose runs open nothing")
    func proseOpensNothing() {
        let context = MarkdownContext(nameWithOwner: "phmatray/Elliot")
        for run: InlineText.Run in [.text("a"), .emphasis("b"), .strong("c"), .code("swift test")] {
            #expect(context.url(for: run) == nil)
        }
    }

    // MARK: - What is flowed, and what is one Text

    /// The fast path is a cost decision, not a styling one: a line with nothing
    /// to click is one `Text`. If this predicate ever says "yes" for plain
    /// prose, every paragraph in a several-hundred-line body becomes one view
    /// per word.
    @Test("Only a line with something clickable is flowed")
    func flowingIsOnlyForClickableLines() {
        #expect(!InlineTextView.isFlowing(InlineText(runs: [.text("plain prose")])))
        #expect(!InlineTextView.isFlowing(InlineText(runs: [.code("swift test"), .strong("bold")])))

        #expect(InlineTextView.isFlowing(InlineText(runs: [.text("see "), .issueRef(47)])))
        #expect(InlineTextView.isFlowing(InlineText(runs: [.prRef(72)])))
        #expect(InlineTextView.isFlowing(InlineText(runs: [.path("a/b.swift")])))
        #expect(InlineTextView.isFlowing(InlineText(runs: [.link(text: "docs", url: "https://x")])))
    }

    /// Words, because a flow layout wraps *between* subviews. A code span stays
    /// whole — split, it would draw as two spans — and a chip is one piece
    /// carrying the URL the reference resolved to.
    @Test("A flowed line breaks into words, whole code spans and chips")
    func piecesSplitIntoWordsAndChips() {
        let context = MarkdownContext(nameWithOwner: "phmatray/Elliot")
        let line = InlineText(runs: [
            .text("closes "),
            .issueRef(47),
            .text(" via "),
            .code("swift test"),
            .text(" and "),
            .prRef(72),
        ])

        let pieces = InlineTextView.pieces(of: line, context: context)

        #expect(pieces == [
            .word("closes", .plain),
            .chip(text: "#47", symbol: "circle.dashed", url: "https://github.com/phmatray/Elliot/issues/47"),
            .word("via", .plain),
            .code("swift test"),
            .word("and", .plain),
            .chip(text: "PR 72", symbol: "arrow.triangle.pull", url: "https://github.com/phmatray/Elliot/pull/72"),
        ])
    }

    @Test("Emphasis and strength survive the word split")
    func emphasisSurvivesTheSplit() {
        let line = InlineText(runs: [
            .strong("no branch filter"), .text(" — see "), .path("a/b.swift"), .emphasis("really now"),
        ])
        let pieces = InlineTextView.pieces(of: line, context: .unresolved)

        #expect(pieces.prefix(3) == [.word("no", .strong), .word("branch", .strong), .word("filter", .strong)])
        #expect(pieces.suffix(2) == [.word("really", .emphasis), .word("now", .emphasis)])
        #expect(pieces.contains(.chip(text: "a/b.swift", symbol: "doc.text", url: nil)))
    }

    // MARK: - Line breaking

    /// The one part of the inline renderer that can be wrong arithmetically
    /// rather than visually.
    @Test("A flow packs a line until it does not fit, then starts another")
    func flowWraps() {
        // 4 × 30pt + 3 × 5pt spacing = 135 > 100, so the fourth wraps.
        let rows = InlineFlow.rows(widths: [30, 30, 30, 30], maxWidth: 100, spacing: 5)
        #expect(rows == [0..<3, 3..<4])
    }

    @Test("Everything that fits stays on one line")
    func flowKeepsOneLine() {
        #expect(InlineFlow.rows(widths: [10, 10, 10], maxWidth: 500, spacing: 4) == [0..<3])
    }

    /// A word wider than the panel still gets a line — dropping it would be the
    /// silent kind of failure this whole file is written against.
    @Test("A subview wider than the line still gets a line of its own")
    func flowNeverDropsAnOversizedItem() {
        let rows = InlineFlow.rows(widths: [10, 400, 10], maxWidth: 100, spacing: 4)
        #expect(rows == [0..<1, 1..<2, 2..<3])
    }

    @Test("The rows cover every subview exactly once, in order")
    func flowIsATotalPartition() {
        let widths: [CGFloat] = [12, 40, 8, 90, 33, 7, 61, 4]
        for maxWidth in [40, 90, 140, 300] as [CGFloat] {
            let rows = InlineFlow.rows(widths: widths, maxWidth: maxWidth, spacing: 4)
            #expect(rows.flatMap { Array($0) } == Array(widths.indices),
                    "maxWidth \(maxWidth) lost or reordered a subview")
        }
        #expect(InlineFlow.rows(widths: [], maxWidth: 100, spacing: 4).isEmpty)
    }

    // MARK: - The meter

    /// The meter is the only number the pane prints about the body's own
    /// content, and criterion 15 is that it equals the ticked boxes.
    @Test("The task meter counts the ticked boxes of its own list")
    func meterCountsTicks() {
        let items = [
            TaskItem(done: true, text: InlineText(runs: [.text("one")])),
            TaskItem(done: false, text: InlineText(runs: [.text("two")])),
            TaskItem(done: true, text: InlineText(runs: [.text("three")])),
        ]
        let meter = TaskListBlock.meter(items)

        #expect(meter.done == 2)
        #expect(meter.total == 3)
        #expect(meter.text == "2 / 3")
        #expect(TaskListBlock.meter([]).text == "0 / 0")
    }

    /// Against the real fixture rather than a hand-built list, so the meter is
    /// tied to what a parsed body actually produces.
    @Test("The meter matches the ticked boxes in the template fixture")
    func meterMatchesTheFixture() throws {
        let parsed = document(Self.issueFixture("full-template.md"))
        let lists = allBlocks(parsed.blocks).compactMap { block -> [TaskItem]? in
            if case .taskList(let items) = block { return items }
            return nil
        }
        let items = try #require(lists.first, "full-template.md no longer carries a task list")

        // Counted from the fixture's own `- [x]` lines, not from the parse, so
        // the two are checked against each other rather than against a shared
        // mistake.
        let ticked = Self.issueFixture("full-template.md")
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix("- [x]") }
            .count

        #expect(TaskListBlock.meter(items).done == ticked)
        #expect(TaskListBlock.meter(items).text == "\(ticked) / \(items.count)")
    }

    // MARK: - What a screen reader hears

    /// Every block is one combined element whose label leads with its kind.
    /// Asserted over one of each case, because the rule is about the set, and a
    /// twelfth case added without a label is exactly the kind of omission that
    /// draws fine and reads as nothing.
    @Test("Every block's label leads with its kind")
    func everyLabelLeadsWithItsKind() {
        for block in Self.oneOfEachBlock {
            let label = MarkdownAccessibility.label(for: block)
            let kind = MarkdownAccessibility.kind(of: block)
            #expect(label.hasPrefix(kind), "\(kind) label was \"\(label)\"")
            #expect(!kind.isEmpty)
        }
    }

    @Test("A label carries the block's content, not only its kind")
    func labelsCarryContent() {
        let criteria = IssueBlock.orderedList([
            InlineText(runs: [.text("It builds")]),
            InlineText(runs: [.text("It runs")]),
        ])
        let label = MarkdownAccessibility.label(for: criteria)
        #expect(label == "Numbered list, 2 items. 1. It builds 2. It runs")

        let tasks = IssueBlock.taskList([
            TaskItem(done: true, text: InlineText(runs: [.text("one")])),
            TaskItem(done: false, text: InlineText(runs: [.text("two")])),
        ])
        #expect(MarkdownAccessibility.label(for: tasks).hasPrefix("Task list, 1 of 2 done."))

        let callout = IssueBlock.callout(kind: "IMPORTANT", body: [
            .paragraph(InlineText(runs: [.text("Six thousand lines went in on one machine's word.")])),
        ])
        #expect(MarkdownAccessibility.label(for: callout).hasPrefix("Callout, important."))

        let fold = IssueBlock.collapsible(
            summary: InlineText(runs: [.text("📋 Spec")]), body: [], lineCount: 42
        )
        #expect(MarkdownAccessibility.label(for: fold) == "Collapsible. 📋 Spec, 42 lines hidden.")
    }

    /// A story's three clauses are spoken in order and captioned the way they
    /// are drawn. A half-written story speaks only the clauses it has.
    @Test("A user story is spoken clause by clause, and a missing clause is silent")
    func userStorySpeaksItsClauses() {
        let full = IssueBlock.userStory(role: "maintainer", want: "a workflow", benefit: "a green tick means something")
        #expect(MarkdownAccessibility.label(for: full)
            == "User story. As a maintainer. I want a workflow. So that a green tick means something.")

        let partial = IssueBlock.userStory(role: "maintainer", want: "a workflow", benefit: "")
        #expect(MarkdownAccessibility.label(for: partial) == "User story. As a maintainer. I want a workflow.")
    }

    // MARK: - The whole fixture

    /// Criterion 15 names eight components. This asserts the pane is handed one
    /// of each by a real body — a rendering test cannot run here, but "there was
    /// nothing to render" is the other way criterion 15 fails, and that is
    /// decidable.
    @Test("The template fixture yields every component criterion 15 names")
    func theFixtureCarriesEveryComponent() {
        let blocks = allBlocks(document(Self.issueFixture("full-template.md")).blocks)
        let kinds = Set(blocks.map(MarkdownAccessibility.kind(of:)))

        for required in ["User story", "Numbered list", "Task list", "Code", "Table", "Callout", "Collapsible"] {
            #expect(kinds.contains(required), "full-template.md no longer produces a \(required) block")
        }

        // And every one of them is labelled — a block that draws but says
        // nothing is unreachable with VoiceOver on.
        for block in blocks {
            #expect(!MarkdownAccessibility.label(for: block).isEmpty)
        }
    }

    /// The fixture's `#47`, `PR 72` and path references become chips that open
    /// this repository, and a reference *inside a fence* stays code — the
    /// parser guarantees that, and the pane must not undo it by chipping a
    /// fence's text.
    @Test("A reference inside a code fence is never a chip")
    func fencesDoNotProduceChips() {
        let blocks = allBlocks(document(Self.issueFixture("full-template.md")).blocks)
        let fences = blocks.compactMap { block -> String? in
            if case .codeFence(_, let code) = block { return code }
            return nil
        }
        #expect(fences.contains { $0.contains("#47") }, "the fixture no longer hides a #47 in a fence")

        let chipped = blocks.flatMap(Self.inlineTexts).flatMap { text in
            InlineTextView.pieces(of: text, context: MarkdownContext(nameWithOwner: "phmatray/Elliot"))
        }
        .compactMap { piece -> String? in
            if case .chip(let text, _, _) = piece { return text }
            return nil
        }

        // The prose really does reference the issue and the PR…
        #expect(chipped.contains("#47"))
        #expect(chipped.contains("PR 72"))
        // …and a code fence contributes no inline text at all, so its `#47`
        // cannot become one.
        #expect(!blocks.contains { if case .codeFence = $0 { return !Self.inlineTexts($0).isEmpty } else { return false } })
    }

    // MARK: - Helpers

    /// Callouts, quotes and collapsibles hold blocks of their own.
    private func allBlocks(_ blocks: [IssueBlock]) -> [IssueBlock] {
        blocks.flatMap { block -> [IssueBlock] in
            switch block {
            case .callout(_, let body), .quote(let body), .collapsible(_, let body, _):
                return [block] + allBlocks(body)
            default:
                return [block]
            }
        }
    }

    /// Every inline line a block carries directly. A code fence carries none —
    /// its content is a string, never runs — which is what keeps a `#47` inside
    /// one from ever becoming a chip.
    private static func inlineTexts(_ block: IssueBlock) -> [InlineText] {
        switch block {
        case .heading(_, let text), .paragraph(let text):
            return [text]
        case .orderedList(let items), .bulletList(let items):
            return items
        case .taskList(let items):
            return items.map(\.text)
        case .table(let header, let rows):
            return header + rows.flatMap { $0 }
        case .collapsible(let summary, _, _):
            return [summary]
        case .userStory, .codeFence, .callout, .quote, .rule:
            return []
        }
    }

    private static let oneOfEachBlock: [IssueBlock] = [
        .heading(level: 2, text: InlineText(runs: [.text("Problem")])),
        .paragraph(InlineText(runs: [.text("Nothing runs.")])),
        .userStory(role: "maintainer", want: "a workflow", benefit: "a tick means something"),
        .orderedList([InlineText(runs: [.text("It builds")])]),
        .bulletList([InlineText(runs: [.text("A hosted runner")])]),
        .taskList([TaskItem(done: true, text: InlineText(runs: [.text("Add the workflow")]))]),
        .codeFence(language: "yaml", code: "on:\n  push:"),
        .callout(kind: "IMPORTANT", body: [.paragraph(InlineText(runs: [.text("Read this.")]))]),
        .quote([.paragraph(InlineText(runs: [.text("Someone said this.")]))]),
        .table(header: [InlineText(runs: [.text("Step")])], rows: [[InlineText(runs: [.text("Build")])]]),
        .collapsible(summary: InlineText(runs: [.text("Spec")]), body: [], lineCount: 3),
        .rule,
    ]
}
