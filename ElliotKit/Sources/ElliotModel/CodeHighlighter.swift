import Foundation

/// What a run of characters inside a fenced code block is.
///
/// Four cases and no more. This is a *cue reader*, not a parser: it says
/// "this looks like a comment" with the confidence a shared convention gives,
/// and says `.plain` for everything else. There is no `.number`, no `.type`,
/// no `.function` — each of those needs a grammar to be right more often than
/// it is wrong, and a token coloured wrongly is worse than a token not
/// coloured at all.
public enum CodeTokenKind: String, Sendable, Hashable, CaseIterable {
    case plain
    case keyword
    case string
    case comment
}

/// One contiguous run of a code fence, and what it looked like.
public struct CodeToken: Sendable, Hashable {
    public var text: String
    public var kind: CodeTokenKind

    public init(text: String, kind: CodeTokenKind) {
        self.text = text
        self.kind = kind
    }
}

/// The smallest tokeniser that earns its place in a code fence.
///
/// **Total, in the same sense `IssueMarkdownParser.parse` is**: it never
/// throws and never drops a character. `tokens(of:).map(\.text).joined()` is
/// the input, byte for byte — which is the property that makes "the fence
/// still shows what the author wrote" a thing a test can hold rather than a
/// thing a reader has to notice.
///
/// ### Deliberately language-agnostic
///
/// There is no `language` parameter, and that is the design rather than an
/// omission. The fences in this repository's issues are swift, yaml, bash and
/// json, and three shared conventions cover all four:
///
/// - a comment runs from `#` or `//` to the end of the line;
/// - a string is whatever sits between a matched pair of quotes on one line;
/// - a small set of words are keywords in more than one of those languages.
///
/// A per-language grammar would colour more and be wrong more. Every rule
/// below is written to **fail to `.plain`** rather than to guess: an
/// unterminated quote is not a string, a `#` with no space after it is not a
/// comment, and a word that is not in the list is nothing at all.
///
/// ### What it deliberately does not do
///
/// - No `/* … */`. A block comment spans lines, and a cue that can swallow the
///   rest of a fence on one mis-read is the wrong trade at this size.
/// - No numbers, no YAML keys, no JSON keys. The approved mockup tints a YAML
///   key like a keyword and its scalar like a string; doing that here means
///   knowing the document is YAML, which is the grammar this type refuses to
///   have. Unquoted YAML renders plain, and that is the honest outcome.
/// - No highlighting of **inline** code spans. `InlineText.Run.code` is
///   rendered by its own view and never comes through here; syntax colour
///   exists only inside a fence's own surface, which is what stops it reading
///   as one of the board's consequence colours. See `CodeFenceBlock`.
public enum CodeHighlighter {

    /// Words that are keywords in more than one of the four languages that
    /// actually appear in this repository's issue bodies.
    ///
    /// Short on purpose. Every entry here is a word that would be a keyword to
    /// a reader of swift, bash, yaml or json — never a library name, never a
    /// command (`echo`, `swift`, `git` are programs, not syntax), never a
    /// field name. A list that grows past what a reader would agree with stops
    /// meaning "this is syntax" and starts meaning "this word was in a list".
    public static let keywords: Set<String> = [
        // Swift
        "associatedtype", "async", "await", "case", "catch", "class", "defer",
        "deinit", "do", "else", "enum", "extension", "fileprivate", "for",
        "func", "guard", "if", "import", "in", "init", "internal", "let",
        "nil", "private", "protocol", "public", "repeat", "return", "self",
        "static", "struct", "subscript", "switch", "throw", "throws", "try",
        "typealias", "var", "where", "while",
        // Shell
        "done", "elif", "esac", "export", "fi", "function", "local", "then",
        "unset",
        // JSON and YAML literals
        "false", "null", "true",
    ]

    /// The characters a quote may follow and still open a string.
    ///
    /// This is the guard that keeps an apostrophe in `don't` from opening a
    /// string that closes on the next apostrophe three words later. A quote
    /// that opens a string in real code follows an operator, a bracket or
    /// nothing — never a letter.
    private static let quoteOpeners: Set<Character> = ["(", "[", "{", "=", ":", ",", "+"]

    /// The fence, in order, with every character accounted for.
    public static func tokens(of code: String) -> [CodeToken] {
        var out: [CodeToken] = []
        // `components(separatedBy:)` round-trips exactly under `joined`, which
        // is what keeps the totality property true across line endings.
        for (offset, line) in code.components(separatedBy: "\n").enumerated() {
            if offset > 0 { append(&out, "\n", .plain) }
            appendTokens(of: line, to: &out)
        }
        return out
    }

    // MARK: - One line

    private static func appendTokens(of line: String, to out: inout [CodeToken]) {
        let chars = Array(line)
        var index = 0
        var plainFrom = 0

        func flushPlain(upTo end: Int) {
            guard end > plainFrom else { return }
            append(&out, String(chars[plainFrom..<end]), .plain)
        }

        while index < chars.count {
            if isCommentStart(chars, at: index) {
                flushPlain(upTo: index)
                append(&out, String(chars[index...]), .comment)
                plainFrom = chars.count
                index = chars.count
                continue
            }

            if let close = stringClose(chars, from: index) {
                flushPlain(upTo: index)
                append(&out, String(chars[index...close]), .string)
                index = close + 1
                plainFrom = index
                continue
            }

            if isWordStart(chars[index]) {
                var end = index
                while end < chars.count, isWordBody(chars[end]) { end += 1 }
                // The whole word is stepped over whether or not it matched, so
                // `iffy` can never contribute an `if` and `println` can never
                // contribute an `in`.
                if keywords.contains(String(chars[index..<end])) {
                    flushPlain(upTo: index)
                    append(&out, String(chars[index..<end]), .keyword)
                    plainFrom = end
                }
                index = end
                continue
            }

            index += 1
        }

        flushPlain(upTo: chars.count)
    }

    // MARK: - The three cues

    /// `#` or `//`, at the start of a line or after whitespace.
    ///
    /// Both halves of that condition are load-bearing. Requiring whitespace
    /// before `//` is what stops `https://example.com` becoming a comment —
    /// the slashes there follow a colon. Requiring whitespace, `!` or `#`
    /// *after* a `#` is what stops Swift's `#if` and `#available` becoming one.
    private static func isCommentStart(_ chars: [Character], at index: Int) -> Bool {
        guard index == 0 || chars[index - 1].isWhitespace else { return false }
        switch chars[index] {
        case "#":
            // A `#` at the end of a line has nothing after it to judge, and a
            // lone `#` is a comment in every language that has `#` comments.
            guard index + 1 < chars.count else { return true }
            let next = chars[index + 1]
            return next.isWhitespace || next == "!" || next == "#"
        case "/":
            return index + 1 < chars.count && chars[index + 1] == "/"
        default:
            return false
        }
    }

    /// Where the string opening at `index` closes, or `nil` if nothing here
    /// opens one.
    ///
    /// Single-line only, and unterminated means `.plain`: a quote that never
    /// closes is far more likely to be an apostrophe than a string someone
    /// forgot to finish, and tinting the rest of the fence on that guess is
    /// exactly the failure this type is scoped to avoid.
    private static func stringClose(_ chars: [Character], from index: Int) -> Int? {
        let quote = chars[index]
        guard quote == "\"" || quote == "'" else { return nil }
        guard
            index == 0
                || chars[index - 1].isWhitespace
                || quoteOpeners.contains(chars[index - 1])
        else { return nil }

        var cursor = index + 1
        while cursor < chars.count {
            // Only double quotes take backslash escapes — a shell's single
            // quotes are literal, so `'\'` closes there and would not here.
            if quote == "\"", chars[cursor] == "\\" {
                cursor += 2
                continue
            }
            if chars[cursor] == quote { return cursor }
            cursor += 1
        }
        return nil
    }

    private static func isWordStart(_ character: Character) -> Bool {
        character.isLetter || character == "_"
    }

    private static func isWordBody(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    // MARK: - Emitting

    /// Appends, merging into the previous token when the kind is the same, so
    /// the view builds one `Text` segment per run rather than one per
    /// character.
    private static func append(
        _ out: inout [CodeToken], _ text: String, _ kind: CodeTokenKind
    ) {
        guard !text.isEmpty else { return }
        if let last = out.last, last.kind == kind {
            out[out.count - 1] = CodeToken(text: last.text + text, kind: kind)
            return
        }
        out.append(CodeToken(text: text, kind: kind))
    }
}
