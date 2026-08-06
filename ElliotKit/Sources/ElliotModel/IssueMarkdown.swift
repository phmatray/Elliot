import Foundation

/// One structural piece of a GitHub issue body.
///
/// A card's `body` is the verbatim issue body, which is arbitrary user prose
/// rather than a template, so this model exists to be *rendered*, not to be
/// authoritative: `IssueMarkdownParser` degrades anything it does not
/// recognise to `.paragraph`, and a paragraph keeps its line's text verbatim.
/// Nothing here is ever parsed back out for a fact — issue and PR numbers come
/// from `gh` through `GHClient`, never from a body.
public enum IssueBlock: Sendable, Hashable {
    case heading(level: Int, text: InlineText)
    case paragraph(InlineText)
    /// "As a … I want … so that …", split so the panel can caption the parts.
    case userStory(role: String, want: String, benefit: String)
    /// A run of `1.` `2.` `3.` … items — the acceptance criteria, usually.
    case orderedList([InlineText])
    case bulletList([InlineText])
    /// `- [x] …` / `- [ ] …`, the checklist `implement-issue` ticks as it works.
    case taskList([TaskItem])
    case codeFence(language: String?, code: String)
    /// `> [!IMPORTANT]`. `kind` is kept exactly as the author wrote it; the view
    /// decides how to caption it, and renders it greyscale — letting an issue
    /// author's callout paint the panel amber would let arbitrary prose imitate
    /// a run state.
    case callout(kind: String, body: [IssueBlock])
    case quote([IssueBlock])
    case table(header: [InlineText], rows: [[InlineText]])
    /// `<details>`. `lineCount` is how many source lines it hides, which is what
    /// the summary row reports before it is opened.
    case collapsible(summary: InlineText, body: [IssueBlock], lineCount: Int)
    case rule
}

public struct TaskItem: Sendable, Hashable {
    public var done: Bool
    public var text: InlineText

    public init(done: Bool, text: InlineText) {
        self.done = done
        self.text = text
    }
}

/// Inline runs, so `#47`, `PR 72`, paths and `code` spans survive segmentation.
public struct InlineText: Sendable, Hashable {
    public var runs: [Run]

    public init(runs: [Run] = []) {
        self.runs = runs
    }

    public enum Run: Sendable, Hashable {
        case text(String)
        case emphasis(String)
        case strong(String)
        case code(String)
        case issueRef(Int)        // #47 — never inside a code span or fence
        case prRef(Int)           // PR 72
        case path(String)         // a/b.swift, .github/workflows/ci.yml
        case link(text: String, url: String)
    }

    /// Every run's characters, in order — the text a reader sees and a screen
    /// reader speaks, with the markup taken off.
    public var plain: String {
        runs.map { run -> String in
            switch run {
            case .text(let s), .emphasis(let s), .strong(let s), .code(let s), .path(let s):
                return s
            case .issueRef(let number):
                return "#\(number)"
            case .prRef(let number):
                return "PR \(number)"
            case .link(let text, _):
                return text
            }
        }
        .joined()
    }

    /// The same runs with their markers put back on.
    ///
    /// This is not for display — it is what makes the parser's totality
    /// checkable: a block flattened through `marked` still carries the
    /// characters the source line carried, so "no line was dropped" is a
    /// property a test can state about the source rather than about the parse.
    public var marked: String {
        runs.map { run -> String in
            switch run {
            case .text(let s), .path(let s):
                return s
            case .emphasis(let s):
                return "*\(s)*"
            case .strong(let s):
                return "**\(s)**"
            case .code(let s):
                return "`\(s)`"
            case .issueRef(let number):
                return "#\(number)"
            case .prRef(let number):
                return "PR \(number)"
            case .link(let text, let url):
                return "[\(text)](\(url))"
            }
        }
        .joined()
    }

    public var isEmpty: Bool { plain.trimmed().isEmpty }
}

// MARK: - Flattening, and why it re-emits markers

extension IssueBlock {
    /// The block flattened back to marked-up text.
    ///
    /// Markers are *canonical* rather than verbatim — a `*` bullet comes back as
    /// `-`, a table's alignment row as `| :---: |` — so this is a rendering of
    /// the parse, not a copy of the source. It exists for one purpose: the
    /// parser promises never to drop a line, and this is what lets a test hold
    /// it to that promise across a whole document.
    public var plainText: String {
        switch self {
        case .heading(let level, let text):
            return String(repeating: "#", count: max(1, level)) + " " + text.marked
        case .paragraph(let text):
            return text.marked
        case .userStory(let role, let want, let benefit):
            return "As a \(role), I want \(want), so that \(benefit)"
        case .orderedList(let items):
            return items.enumerated()
                .map { "\($0.offset + 1). \($0.element.marked)" }
                .joined(separator: "\n")
        case .bulletList(let items):
            return items.map { "- " + $0.marked }.joined(separator: "\n")
        case .taskList(let items):
            return items.map { "- [\($0.done ? "x" : " ")] " + $0.text.marked }.joined(separator: "\n")
        case .codeFence(let language, let code):
            return "```" + (language ?? "") + "\n" + code + "\n```"
        case .callout(let kind, let body):
            return quoted(["[!\(kind)]"] + body.map(\.plainText))
        case .quote(let body):
            return quoted(body.map(\.plainText))
        case .table(let header, let rows):
            let alignment = "| " + header.map { _ in ":---:" }.joined(separator: " | ") + " |"
            return ([Self.row(header), alignment] + rows.map(Self.row)).joined(separator: "\n")
        case .collapsible(let summary, let body, _):
            return "<details>\n<summary>\(summary.marked)</summary>\n"
                + body.map(\.plainText).joined(separator: "\n")
                + "\n</details>"
        case .rule:
            return "---"
        }
    }

    private static func row(_ cells: [InlineText]) -> String {
        "| " + cells.map(\.marked).joined(separator: " | ") + " |"
    }

    private func quoted(_ parts: [String]) -> String {
        parts
            .flatMap { $0.components(separatedBy: "\n") }
            .map { "> " + $0 }
            .joined(separator: "\n")
    }
}

// MARK: - The document

public struct IssueDocument: Sendable, Hashable {
    public var blocks: [IssueBlock]
    /// The first `.orderedList` under an "Acceptance criteria" heading, else [].
    public var acceptanceCriteria: [InlineText]

    public init(blocks: [IssueBlock]) {
        self.blocks = blocks
        self.acceptanceCriteria = Self.criteria(in: blocks)
    }

    /// (done, total) over every `.taskList` in the document, nested ones
    /// included. `nil` when there is none — an issue with no checklist should
    /// show no meter rather than an empty one.
    ///
    /// Computed rather than stored because a labelled tuple defeats the
    /// synthesis of `Hashable`.
    public var taskProgress: (done: Int, total: Int)? {
        let items = Self.tasks(in: blocks)
        guard !items.isEmpty else { return nil }
        return (items.filter(\.done).count, items.count)
    }

    /// A flattening of every block, in order. See `IssueBlock.plainText`.
    public var plainText: String {
        blocks.map(\.plainText).joined(separator: "\n")
    }

    private static func tasks(in blocks: [IssueBlock]) -> [TaskItem] {
        blocks.flatMap { block -> [TaskItem] in
            switch block {
            case .taskList(let items):
                return items
            case .callout(_, let body), .quote(let body), .collapsible(_, let body, _):
                return tasks(in: body)
            default:
                return []
            }
        }
    }

    private static func criteria(in blocks: [IssueBlock]) -> [InlineText] {
        for (index, block) in blocks.enumerated() {
            guard
                case .heading(let level, let text) = block,
                text.plain.lowercased().contains("acceptance criteria")
            else { continue }

            // The list is rarely the very next block — this repo's own issues
            // put a paragraph of caveats between the heading and item 1.
            for next in blocks[(index + 1)...] {
                if case .heading(let otherLevel, _) = next, otherLevel <= level { break }
                if case .orderedList(let items) = next { return items }
            }
        }
        return []
    }
}
