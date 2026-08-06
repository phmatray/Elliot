import Foundation

/// Turns a GitHub issue body into `IssueBlock`s.
///
/// **Total, in the same sense `StreamEventDecoder.decode` is**: it never throws
/// and never drops a line. Anything it does not recognise degrades to
/// `.paragraph`, which keeps the line's text verbatim, so a body written in a
/// shape nobody anticipated renders as prose rather than as an empty panel —
/// the failure mode that matters here, because a mis-segmented body produces no
/// error, no crash and no failing test, just a panel with less in it.
///
/// Hand-written rather than a dependency: the output has to be `Sendable` under
/// `swiftLanguageModes: [.v6]`, totality is the contract and a general-purpose
/// library does not promise it, and this repository has no CI — a dependency
/// that stops resolving would be discovered by a human at the wrong moment.
///
/// Three recognitions are deliberately narrower than CommonMark, each because
/// being wrong costs more than being incomplete:
///
/// - **`_` is never emphasis.** `snake_case`, `feat/79-inline_detail` and half
///   the identifiers in this repository would be mangled by it. Only `*` and
///   `**` are read as markup.
/// - **A user story is matched case-sensitively** on "As a … , I want … , so
///   that …". A sentence the parser is not sure about stays a paragraph rather
///   than being reflowed into three captions that misattribute their clauses.
/// - **An ordered list must be numbered 1, 2, 3 …** from 1. A run starting at
///   `3.` stays prose: the panel prints the ordinal, and silently renumbering
///   someone's list is the kind of quiet lie this app exists to avoid.
public enum IssueMarkdownParser {

    /// Total: never throws, never drops a line. Anything unrecognised becomes
    /// `.paragraph`. The same discipline as `StreamEventDecoder.decode`.
    public static func parse(_ body: String) -> IssueDocument {
        IssueDocument(blocks: blocks(in: lines(of: body)))
    }

    /// CRLF and a lone CR both become LF. Line endings arrive from whatever
    /// wrote the issue, and `\r` left in place turns every trailing token into
    /// one that matches nothing.
    static func lines(of body: String) -> [String] {
        body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    // MARK: - Blocks

    static func blocks(in lines: [String]) -> [IssueBlock] {
        var out: [IssueBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmed()

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if let language = fenceOpener(trimmed) {
                var code: [String] = []
                index += 1
                while index < lines.count, !isFenceCloser(lines[index].trimmed()) {
                    code.append(lines[index])
                    index += 1
                }
                // An unterminated fence closes at end of file rather than
                // swallowing the rest of the document into nothing.
                if index < lines.count { index += 1 }
                out.append(.codeFence(language: language, code: code.joined(separator: "\n")))
                continue
            }

            if isDetailsOpener(trimmed) {
                let (block, next) = collapsible(in: lines, from: index)
                out.append(block)
                index = next
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoted: [String] = []
                while index < lines.count, lines[index].trimmed().hasPrefix(">") {
                    quoted.append(unquote(lines[index]))
                    index += 1
                }
                out.append(quoteBlock(quoted))
                continue
            }

            if let (level, text) = heading(trimmed) {
                out.append(.heading(level: level, text: inline(text)))
                index += 1
                continue
            }

            if trimmed == "---" {
                out.append(.rule)
                index += 1
                continue
            }

            if isTableRow(trimmed), index + 1 < lines.count, isTableAlignment(lines[index + 1].trimmed()) {
                let header = cells(trimmed)
                index += 2
                var rows: [[InlineText]] = []
                while index < lines.count, isTableRow(lines[index].trimmed()) {
                    rows.append(cells(lines[index].trimmed()))
                    index += 1
                }
                out.append(.table(header: header, rows: rows))
                continue
            }

            if let first = listItem(trimmed), first.family != .ordered || first.ordinal == 1 {
                let (items, next) = gatherList(lines, from: index, family: first.family)
                index = next
                switch first.family {
                case .task:
                    out.append(.taskList(items.map { TaskItem(done: $0.done, text: inline($0.text)) }))
                case .bullet:
                    out.append(.bulletList(items.map { inline($0.text) }))
                case .ordered:
                    out.append(.orderedList(items.map { inline($0.text) }))
                }
                continue
            }

            // Everything else is prose, and prose is kept verbatim.
            var paragraph: [String] = []
            while index < lines.count {
                let next = lines[index].trimmed()
                if next.isEmpty || (!paragraph.isEmpty && startsABlock(lines, at: index)) { break }
                paragraph.append(next)
                index += 1
            }
            let text = paragraph.joined(separator: " ")
            out.append(userStory(text) ?? .paragraph(inline(text)))
        }

        return out
    }

    /// True when the main loop above would open a new block at `index`. Used
    /// only to end a paragraph, so the two must agree — a predicate that said
    /// "yes" where the loop says "no" would cut a paragraph in half.
    private static func startsABlock(_ lines: [String], at index: Int) -> Bool {
        let trimmed = lines[index].trimmed()
        if trimmed.isEmpty { return true }
        if fenceOpener(trimmed) != nil { return true }
        if isDetailsOpener(trimmed) { return true }
        if trimmed.hasPrefix(">") { return true }
        if heading(trimmed) != nil { return true }
        if trimmed == "---" { return true }
        if isTableRow(trimmed), index + 1 < lines.count, isTableAlignment(lines[index + 1].trimmed()) {
            return true
        }
        if let item = listItem(trimmed) { return item.family != .ordered || item.ordinal == 1 }
        return false
    }

    // MARK: - Headings, rules, fences

    private static func heading(_ trimmed: String) -> (level: Int, text: String)? {
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        // `#47` is a reference, not a heading: a marker needs its space.
        guard rest.isEmpty || rest.first == " " else { return nil }
        return (hashes.count, String(rest).trimmed())
    }

    /// The info string of a ``` fence, or nil when the line does not open one.
    private static func fenceOpener(_ trimmed: String) -> String?? {
        guard trimmed.hasPrefix("```") else { return nil }
        let info = String(trimmed.dropFirst(3)).trimmed()
        return .some(info.isEmpty ? nil : info)
    }

    private static func isFenceCloser(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("```") && String(trimmed.dropFirst(3)).trimmed().isEmpty
    }

    // MARK: - Quotes and callouts

    private static func unquote(_ line: String) -> String {
        var rest = Substring(line.trimmed())
        guard rest.first == ">" else { return line }
        rest = rest.dropFirst()
        if rest.first == " " { rest = rest.dropFirst() }
        return String(rest)
    }

    private static func quoteBlock(_ body: [String]) -> IssueBlock {
        var body = body
        if let first = body.firstIndex(where: { !$0.trimmed().isEmpty }),
           let kind = calloutKind(body[first].trimmed()) {
            body.remove(at: first)
            return .callout(kind: kind, body: blocks(in: body))
        }
        return .quote(blocks(in: body))
    }

    /// `[!IMPORTANT]` → `IMPORTANT`, kept exactly as written.
    private static func calloutKind(_ trimmed: String) -> String? {
        guard trimmed.hasPrefix("[!"), trimmed.hasSuffix("]") else { return nil }
        let kind = trimmed.dropFirst(2).dropLast()
        guard !kind.isEmpty, kind.allSatisfy({ $0.isLetter || $0 == "_" || $0 == "-" }) else { return nil }
        return String(kind)
    }

    // MARK: - Collapsibles

    private static func isDetailsOpener(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("<details")
    }

    private static func collapsible(in lines: [String], from start: Int) -> (IssueBlock, Int) {
        var index = start + 1
        var summary = ""

        if lines[start].contains("<summary>") {
            summary = summaryText(lines[start])
        } else if index < lines.count, lines[index].trimmed().hasPrefix("<summary>") {
            var raw = lines[index].trimmed()
            while !raw.contains("</summary>"), index + 1 < lines.count {
                index += 1
                raw += " " + lines[index].trimmed()
            }
            summary = summaryText(raw)
            index += 1
        }

        var depth = 1
        var body: [String] = []
        while index < lines.count {
            let trimmed = lines[index].trimmed()
            if isDetailsOpener(trimmed) { depth += 1 }
            if trimmed.contains("</details>") {
                depth -= 1
                if depth == 0 {
                    index += 1
                    break
                }
            }
            body.append(lines[index])
            index += 1
        }

        // An unclosed `<details>` runs to end of file. GitHub renders it the
        // same way, and the alternative — treating the tag as prose — would put
        // the whole rest of the issue in one paragraph.
        return (
            .collapsible(summary: inline(summary), body: blocks(in: body), lineCount: body.count),
            index
        )
    }

    private static func summaryText(_ raw: String) -> String {
        guard let open = raw.range(of: "<summary>") else { return "" }
        let rest = raw[open.upperBound...]
        guard let close = rest.range(of: "</summary>") else { return String(rest).trimmed() }
        return String(rest[..<close.lowerBound]).trimmed()
    }

    // MARK: - Tables

    private static func isTableRow(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("|") && trimmed.count > 1
    }

    private static func isTableAlignment(_ trimmed: String) -> Bool {
        guard isTableRow(trimmed) else { return false }
        let body = trimmed.filter { $0 != "|" && $0 != " " }
        return body.contains("-") && body.allSatisfy { $0 == "-" || $0 == ":" }
    }

    private static func cells(_ trimmed: String) -> [InlineText] {
        var row = Substring(trimmed)
        if row.first == "|" { row = row.dropFirst() }
        if row.last == "|" { row = row.dropLast() }
        return row.components(separatedBy: "|").map { inline($0.trimmed()) }
    }

    // MARK: - Lists

    private enum ListFamily {
        case task, bullet, ordered
    }

    private struct ListLine {
        var family: ListFamily
        var done: Bool
        var ordinal: Int
        var text: String
    }

    private static func listItem(_ trimmed: String) -> ListLine? {
        if let leader = trimmed.first, "-*+".contains(leader), trimmed.dropFirst().first == " " {
            let rest = String(trimmed.dropFirst(2)).trimmed()
            if let box = checkbox(rest) {
                return ListLine(family: .task, done: box.done, ordinal: 0, text: box.text)
            }
            return ListLine(family: .bullet, done: false, ordinal: 0, text: rest)
        }

        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty, let ordinal = Int(digits) else { return nil }
        let afterDigits = trimmed.dropFirst(digits.count)
        guard let separator = afterDigits.first, separator == "." || separator == ")" else { return nil }
        let rest = afterDigits.dropFirst()
        guard rest.isEmpty || rest.first == " " else { return nil }
        return ListLine(family: .ordered, done: false, ordinal: ordinal, text: String(rest).trimmed())
    }

    private static func checkbox(_ rest: String) -> (done: Bool, text: String)? {
        guard rest.hasPrefix("[") else { return nil }
        let mark = rest.dropFirst().first
        guard mark == " " || mark == "x" || mark == "X" else { return nil }
        let afterMark = rest.dropFirst(2)
        guard afterMark.first == "]" else { return nil }
        return (mark != " ", String(afterMark.dropFirst()).trimmed())
    }

    /// A run of items of one family. Blank lines between items are tolerated —
    /// a "loose" list is still one list — and an indented line that is not
    /// itself an item continues the item above it.
    private static func gatherList(
        _ lines: [String],
        from start: Int,
        family: ListFamily
    ) -> (items: [ListLine], next: Int) {
        var items: [ListLine] = []
        var index = start
        var lastItemEnd = start

        func accepts(_ item: ListLine) -> Bool {
            item.family == family && (family != .ordered || item.ordinal == items.count + 1)
        }

        while index < lines.count {
            let trimmed = lines[index].trimmed()

            if trimmed.isEmpty {
                var lookahead = index + 1
                while lookahead < lines.count, lines[lookahead].trimmed().isEmpty { lookahead += 1 }
                guard
                    lookahead < lines.count,
                    let next = listItem(lines[lookahead].trimmed()),
                    accepts(next)
                else { break }
                index = lookahead
                continue
            }

            if let item = listItem(trimmed), accepts(item) {
                items.append(item)
                index += 1
                lastItemEnd = index
                continue
            }

            if !items.isEmpty, lines[index].first == " " || lines[index].first == "\t" {
                items[items.count - 1].text += " " + trimmed
                index += 1
                lastItemEnd = index
                continue
            }

            break
        }

        // Trailing blank lines belong to whatever comes next, not to the list.
        return (items, max(lastItemEnd, start + 1))
    }

    // MARK: - The user story

    /// "As a maintainer, I want X, so that Y."
    ///
    /// Matched case-sensitively and only in that frame. A near miss stays a
    /// paragraph: three captions built from a sentence the parser guessed at
    /// would read as structure the author never wrote.
    static func userStory(_ text: String) -> IssueBlock? {
        let head: String
        if text.hasPrefix("As a ") {
            head = String(text.dropFirst(5))
        } else if text.hasPrefix("As ") {
            head = String(text.dropFirst(3))
        } else {
            return nil
        }

        guard let want = head.range(of: "I want ") else { return nil }
        let role = String(head[..<want.lowerBound]).trimmingTrailingSeparator()
        let rest = String(head[want.upperBound...])

        guard let benefit = rest.range(of: "so that ") else {
            return .userStory(role: role, want: rest.trimmed(), benefit: "")
        }
        return .userStory(
            role: role,
            want: String(rest[..<benefit.lowerBound]).trimmingTrailingSeparator(),
            benefit: String(rest[benefit.upperBound...]).trimmed()
        )
    }

    // MARK: - Inline runs

    static func inline(_ text: String) -> InlineText {
        var runs: [InlineText.Run] = []
        var buffer = ""
        let chars = Array(text)
        var index = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            runs.append(.text(buffer))
            buffer = ""
        }

        while index < chars.count {
            let character = chars[index]

            // A code span wins over everything else, which is the whole reason
            // `#47` written as `` `#47` `` is not a reference.
            if character == "`", index + 1 < chars.count, chars[index + 1] != "`",
               let close = closingBacktick(chars, from: index + 1) {
                flush()
                runs.append(.code(String(chars[(index + 1)..<close])))
                index = close + 1
                continue
            }

            if character == "[", let link = link(chars, from: index) {
                flush()
                runs.append(.link(text: link.text, url: link.url))
                index = link.end
                continue
            }

            if character == "*", atWordStart(chars, index) {
                if index + 1 < chars.count, chars[index + 1] == "*",
                   let close = closingDoubleStar(chars, from: index + 2), close > index + 2 {
                    flush()
                    runs.append(.strong(String(chars[(index + 2)..<close])))
                    index = close + 2
                    continue
                }
                if let close = closingSingleStar(chars, from: index + 1), close > index + 1 {
                    flush()
                    runs.append(.emphasis(String(chars[(index + 1)..<close])))
                    index = close + 1
                    continue
                }
            }

            if character == "#", atWordStart(chars, index),
               let number = number(chars, from: index + 1), endsAWord(chars, number.end) {
                flush()
                runs.append(.issueRef(number.value))
                index = number.end
                continue
            }

            if character == "P", atWordStart(chars, index), index + 3 < chars.count,
               chars[index + 1] == "R", chars[index + 2] == " ",
               let number = number(chars, from: index + 3), endsAWord(chars, number.end) {
                flush()
                runs.append(.prRef(number.value))
                index = number.end
                continue
            }

            if atWordStart(chars, index), let path = path(chars, from: index) {
                flush()
                runs.append(.path(path.text))
                index = path.end
                continue
            }

            buffer.append(character)
            index += 1
        }

        flush()
        return InlineText(runs: runs)
    }

    private static func atWordStart(_ chars: [Character], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = chars[index - 1]
        return previous.isWhitespace || "([{\"'—–".contains(previous)
    }

    private static func endsAWord(_ chars: [Character], _ index: Int) -> Bool {
        guard index < chars.count else { return true }
        return !chars[index].isLetter && !chars[index].isNumber
    }

    private static func closingBacktick(_ chars: [Character], from index: Int) -> Int? {
        var scan = index
        while scan < chars.count {
            if chars[scan] == "`" { return scan > index ? scan : nil }
            scan += 1
        }
        return nil
    }

    private static func closingDoubleStar(_ chars: [Character], from index: Int) -> Int? {
        var scan = index
        while scan + 1 < chars.count {
            if chars[scan] == "*", chars[scan + 1] == "*" { return scan }
            scan += 1
        }
        return nil
    }

    private static func closingSingleStar(_ chars: [Character], from index: Int) -> Int? {
        guard index < chars.count, chars[index] != " " else { return nil }
        var scan = index
        while scan < chars.count {
            if chars[scan] == "*" {
                if scan + 1 < chars.count, chars[scan + 1] == "*" { return nil }
                return scan
            }
            scan += 1
        }
        return nil
    }

    private static func number(_ chars: [Character], from index: Int) -> (value: Int, end: Int)? {
        var scan = index
        while scan < chars.count, chars[scan].isNumber { scan += 1 }
        guard scan > index, let value = Int(String(chars[index..<scan])) else { return nil }
        return (value, scan)
    }

    private static func link(_ chars: [Character], from index: Int) -> (text: String, url: String, end: Int)? {
        var close = index + 1
        while close < chars.count, chars[close] != "]" { close += 1 }
        guard close + 1 < chars.count, chars[close + 1] == "(" else { return nil }
        var end = close + 2
        while end < chars.count, chars[end] != ")" { end += 1 }
        guard end < chars.count else { return nil }
        return (String(chars[(index + 1)..<close]), String(chars[(close + 2)..<end]), end + 1)
    }

    private static let pathCharacters = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/"
    )

    /// A repository path in prose — `a/b.swift`, `.github/workflows/ci.yml`.
    ///
    /// A URL is not one: `https://…` stops at the colon, which is not a path
    /// character, so the token before it holds no slash and the slash that
    /// follows is not at a word start.
    private static func path(_ chars: [Character], from index: Int) -> (text: String, end: Int)? {
        var end = index
        while end < chars.count, pathCharacters.contains(chars[end]) { end += 1 }
        while end > index, ".,:;-".contains(chars[end - 1]) { end -= 1 }
        guard end > index else { return nil }

        let token = String(chars[index..<end])
        guard token.contains("/") else { return nil }
        let segments = token.components(separatedBy: "/")
        guard let last = segments.last else { return nil }
        guard last.contains(".") || token.hasPrefix(".") else { return nil }
        return (token, end)
    }
}

extension String {
    /// Drops a trailing comma and any whitespace around it. The user story's
    /// flattening puts the comma back, so nothing is lost by taking it off.
    fileprivate func trimmingTrailingSeparator() -> String {
        var text = trimmed()
        while text.hasSuffix(",") { text = String(text.dropLast()).trimmed() }
        return text
    }
}
