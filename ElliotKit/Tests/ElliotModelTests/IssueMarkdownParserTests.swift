import Foundation
import Testing

@testable import ElliotModel

/// Fixtures live at the repository root, not in a resource bundle: the same
/// files are opened by hand when reproducing a body that rendered badly.
private enum FixturePaths {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ElliotModelTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // ElliotKit
        .deletingLastPathComponent()   // repo root

    static func issue(_ name: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent("Fixtures/issues/\(name)"), encoding: .utf8))
            ?? ""
    }
}

// MARK: - Walking a parsed document

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

private func allInline(_ blocks: [IssueBlock]) -> [InlineText] {
    allBlocks(blocks).flatMap { block -> [InlineText] in
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
}

private func allRuns(_ document: IssueDocument) -> [InlineText.Run] {
    allInline(document.blocks).flatMap(\.runs)
}

/// The totality invariant, stated exactly as the spec states it: for every
/// non-blank line of the source, that line's non-whitespace characters appear
/// in the concatenation of every block's plain text, in order.
///
/// One cursor walks the whole document, so this proves order as well as
/// presence — a line that survives but has moved ahead of its neighbours fails
/// just as a dropped one does.
private func expectNothingDropped(
    _ source: String,
    _ document: IssueDocument,
    _ name: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let haystack = Array(document.plainText.filter { !$0.isWhitespace })
    var cursor = 0

    for (offset, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let needle = line.filter { !$0.isWhitespace }
        guard !needle.isEmpty else { continue }
        for character in needle {
            while cursor < haystack.count, haystack[cursor] != character { cursor += 1 }
            guard cursor < haystack.count else {
                Issue.record(
                    """
                    \(name): line \(offset + 1) is not carried through — ran out of document \
                    looking for \"\(character)\" of:
                    \(line)
                    """,
                    sourceLocation: sourceLocation
                )
                return
            }
            cursor += 1
        }
    }
}

@Suite("Issue markdown parser")
struct IssueMarkdownParserTests {

    // MARK: - Totality

    @Test(
        "Every non-blank source line survives the parse",
        arguments: ["full-template.md", "prose-only.md", "adversarial.md"]
    )
    func nothingIsDropped(fixture: String) {
        let source = FixturePaths.issue(fixture)
        #expect(!source.isEmpty, "\(fixture) is missing or empty")
        expectNothingDropped(source, IssueMarkdownParser.parse(source), fixture)
    }

    @Test("Anything unrecognised degrades to a paragraph rather than vanishing")
    func unrecognisedDegradesToParagraph() {
        let document = IssueMarkdownParser.parse("<figure data-x='1'>~~~ not a fence ~~~</figure>")
        guard case .paragraph(let text) = document.blocks.first else {
            Issue.record("expected a paragraph, got \(String(describing: document.blocks.first))")
            return
        }
        #expect(text.plain.contains("not a fence"))
    }

    @Test("Degenerate input parses to an empty document", arguments: ["", "\n\n\n", "   ", "\r\n\r\n"])
    func degenerateInput(body: String) {
        #expect(IssueMarkdownParser.parse(body).blocks.isEmpty)
        #expect(IssueMarkdownParser.parse(body).taskProgress == nil)
    }

    // MARK: - Acceptance criteria: how many, and in which order

    @Test("The acceptance criteria are the ordered list under that heading, in source order")
    func acceptanceCriteria() throws {
        let document = IssueMarkdownParser.parse(FixturePaths.issue("full-template.md"))
        #expect(document.acceptanceCriteria.count == 5)
        let plains = document.acceptanceCriteria.map(\.plain)
        #expect(plains.first?.hasPrefix("A workflow runs on") == true)
        #expect(plains[1].hasPrefix("It runs the profile's") == true)
        #expect(plains[2].hasPrefix("Its pull_request trigger") == true)
        #expect(plains[3].hasPrefix("A failing test fails the job") == true)
        #expect(plains.last?.hasPrefix("The run completes in a bounded time") == true)
    }

    @Test("A body with no acceptance-criteria heading has no criteria")
    func noAcceptanceCriteria() {
        #expect(IssueMarkdownParser.parse(FixturePaths.issue("prose-only.md")).acceptanceCriteria.isEmpty)
        #expect(IssueMarkdownParser.parse(FixturePaths.issue("adversarial.md")).acceptanceCriteria.isEmpty)
    }

    // MARK: - Task progress

    @Test("The meter counts the ticked boxes, not the items")
    func taskProgress() throws {
        let progress = try #require(
            IssueMarkdownParser.parse(FixturePaths.issue("full-template.md")).taskProgress
        )
        #expect(progress.done == 3)
        #expect(progress.total == 6)
    }

    @Test("A task list nested inside an unterminated collapsible still counts")
    func taskProgressInsideACollapsible() throws {
        let progress = try #require(
            IssueMarkdownParser.parse(FixturePaths.issue("adversarial.md")).taskProgress
        )
        #expect(progress.done == 2)
        #expect(progress.total == 3)
    }

    @Test("A body with no checkboxes has no meter at all")
    func noTaskProgress() {
        #expect(IssueMarkdownParser.parse(FixturePaths.issue("prose-only.md")).taskProgress == nil)
    }

    // MARK: - `#47` is a reference in prose and is not one in code

    @Test("#47 in prose becomes an issue reference")
    func issueRefInProse() {
        let document = IssueMarkdownParser.parse(FixturePaths.issue("full-template.md"))
        let refs = allRuns(document).compactMap { run -> Int? in
            if case .issueRef(let number) = run { return number }
            return nil
        }
        // Twice in prose — the Problem paragraph and a Brainstorm bullet. The
        // third `#47` in the fixture is inside a fence and must not be here.
        #expect(refs.filter { $0 == 47 }.count == 2)
        #expect(refs.contains(18) && refs.contains(19) && refs.contains(20))
    }

    @Test("#47 inside a fenced code block is not a reference")
    func issueRefNotInAFence() {
        let document = IssueMarkdownParser.parse(FixturePaths.issue("full-template.md"))
        let fences = allBlocks(document.blocks).compactMap { block -> String? in
            if case .codeFence(_, let code) = block { return code }
            return nil
        }
        // The fence is still there, and it still carries the text verbatim…
        #expect(fences.contains { $0.contains("closes #47") })
        // …but no run anywhere claims it as a reference beyond the two in prose.
        let refs = allRuns(document).filter { if case .issueRef(47) = $0 { return true } else { return false } }
        #expect(refs.count == 2)
    }

    @Test("#47 inside a code span is not a reference")
    func issueRefNotInACodeSpan() {
        let document = IssueMarkdownParser.parse("See `gh issue view #47` before #47 is closed.")
        let runs = allRuns(document)
        #expect(runs.contains { if case .code(let s) = $0 { return s.contains("#47") } else { return false } })
        #expect(runs.filter { if case .issueRef(47) = $0 { return true } else { return false } }.count == 1)
    }

    @Test("A pull-request reference is its own run")
    func prRef() {
        let document = IssueMarkdownParser.parse(FixturePaths.issue("full-template.md"))
        #expect(allRuns(document).contains { if case .prRef(72) = $0 { return true } else { return false } })
    }

    // MARK: - The shapes the panel has to render

    @Test("The repo's own issue shape comes apart into its parts")
    func fullTemplateStructure() throws {
        let document = IssueMarkdownParser.parse(FixturePaths.issue("full-template.md"))
        let blocks = allBlocks(document.blocks)

        guard case .userStory(let role, let want, let benefit)? = blocks.first(where: {
            if case .userStory = $0 { return true } else { return false }
        }) else {
            Issue.record("expected a user story")
            return
        }
        #expect(role == "maintainer")
        #expect(want.hasPrefix("every pull request built and tested"))
        #expect(benefit.hasPrefix("a green tick means the same thing"))

        #expect(blocks.filter { if case .collapsible = $0 { return true } else { return false } }.count == 2)
        #expect(blocks.contains { if case .callout(let kind, _) = $0 { return kind == "IMPORTANT" } else { return false } })
        #expect(blocks.contains { if case .rule = $0 { return true } else { return false } })
        #expect(blocks.contains { if case .codeFence(let language, _) = $0 { return language == "yaml" } else { return false } })

        guard case .table(let header, let rows)? = blocks.first(where: {
            if case .table = $0 { return true } else { return false }
        }) else {
            Issue.record("expected a table")
            return
        }
        #expect(header.map(\.plain) == ["Step", "Command", "Budget"])
        #expect(rows.count == 2)
        #expect(rows[0].map(\.plain) == ["Build", "swift build", "~60 s"])
    }

    @Test("A body with no headings and no lists is nothing but paragraphs")
    func proseOnlyIsAllParagraphs() {
        let document = IssueMarkdownParser.parse(FixturePaths.issue("prose-only.md"))
        #expect(document.blocks.count == 2)
        #expect(document.blocks.allSatisfy { if case .paragraph = $0 { return true } else { return false } })
    }

    @Test("An unterminated fence and an unclosed collapsible both close at end of file")
    func adversarialStructure() throws {
        let document = IssueMarkdownParser.parse(FixturePaths.issue("adversarial.md"))
        let blocks = allBlocks(document.blocks)

        guard case .collapsible(let summary, _, let lineCount)? = blocks.first(where: {
            if case .collapsible = $0 { return true } else { return false }
        }) else {
            Issue.record("expected a collapsible")
            return
        }
        #expect(summary.plain == "Never closed")
        #expect(lineCount > 0)

        guard case .codeFence(let language, let code)? = blocks.first(where: {
            if case .codeFence = $0 { return true } else { return false }
        }) else {
            Issue.record("expected a code fence")
            return
        }
        #expect(language == "swift")
        #expect(code.contains("the file simply ends"))
    }

    @Test("A ragged table keeps every cell each row actually has")
    func raggedTable() throws {
        let document = IssueMarkdownParser.parse(FixturePaths.issue("adversarial.md"))
        guard case .table(let header, let rows)? = allBlocks(document.blocks).first(where: {
            if case .table = $0 { return true } else { return false }
        }) else {
            Issue.record("expected a table")
            return
        }
        #expect(header.count == 2)
        #expect(rows.map(\.count) == [3, 1])
    }

    @Test("A path in prose is its own run, and a URL is not mistaken for one")
    func pathRun() {
        let document = IssueMarkdownParser.parse(FixturePaths.issue("adversarial.md"))
        #expect(allRuns(document).contains {
            if case .path(let p) = $0 { return p == "ElliotKit/Sources/ElliotModel/StreamEvent.swift" }
            return false
        })

        let url = IssueMarkdownParser.parse("See https://github.com/phmatray/Elliot/pull/72 for it.")
        #expect(!allRuns(url).contains { if case .path = $0 { return true } else { return false } })
    }

    // MARK: - Inline plain text is what a reader hears

    @Test("plain drops the markers, marked puts them back")
    func plainAndMarked() {
        let text = IssueMarkdownParser.inline("a **bold** and `code` and [link](https://x.y) and #47")
        #expect(text.plain == "a bold and code and link and #47")
        #expect(text.marked == "a **bold** and `code` and [link](https://x.y) and #47")
    }
}
