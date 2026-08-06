import Foundation
import Testing

@testable import ElliotModel

/// The code fence's syntax cues.
///
/// The suite is built around one property and one refusal.
///
/// The **property** is totality, the same one `IssueMarkdownParser` promises:
/// the tokens concatenate back to the input, character for character. A fence
/// shows source code, and a highlighter that silently drops a backslash or
/// swallows a trailing space has corrupted the one thing the block exists to
/// carry — quietly, with no error and nothing on screen to notice.
///
/// The **refusal** is the other half, and it is what most of these tests are
/// about. `CodeHighlighter` is deliberately a cue reader rather than a parser,
/// so the interesting assertions are not "it found the keyword" but "it did
/// **not** find one": `https://` is not a comment, `#if` is not a comment,
/// `don't` is not a string, `iffy` is not `if`. A tokeniser that guesses badly
/// is worse than none, and every one of those was a way to guess badly.
@Suite("Code highlighter")
struct CodeHighlighterTests {

    /// Every fence in this suite, so the totality property runs against the
    /// awkward inputs rather than against a happy one.
    private let corpus: [String] = [
        "",
        "\n",
        "\n\n\n",
        "   ",
        "let x = 1",
        "let greeting = \"hello\"  // a comment\n",
        "#!/usr/bin/env bash\nset -euo pipefail\nif [ -z \"$1\" ]; then\n  echo 'usage'\nfi\n",
        "on:\n  pull_request:\n    branches: [main]\n  push:\n    branches: [main]\n",
        "jobs:\n  test:\n    runs-on: macos-15\n    timeout-minutes: 15  # criterion 5\n",
        "{\n  \"name\": \"elliot\",\n  \"private\": true,\n  \"main\": null\n}\n",
        "curl https://example.com/a//b",
        "#if os(macOS)\nimport AppKit\n#endif",
        "// it's a comment with don't in it",
        "let s = \"a \\\" quote\" + \"b\"",
        "let unterminated = \"oops",
        "печать 'юникод'",
        "trailing whitespace   ",
        "tabs\tand\tthings",
    ]

    // MARK: - 1. Totality

    @Test("The tokens are the input, character for character")
    func nothingIsEverDropped() {
        for source in corpus {
            let rebuilt = CodeHighlighter.tokens(of: source).map(\.text).joined()
            #expect(
                rebuilt == source,
                """
                A fence renders source code. A highlighter that loses a \
                character has corrupted the one thing the block carries, and \
                it would do so with no error and nothing on screen to notice.
                """
            )
        }
    }

    @Test("No token is empty, and no two neighbours share a kind")
    func tokensAreMinimalRuns() {
        for source in corpus {
            let tokens = CodeHighlighter.tokens(of: source)
            for token in tokens {
                #expect(!token.text.isEmpty)
            }
            for (left, right) in zip(tokens, tokens.dropFirst()) {
                #expect(
                    left.kind != right.kind,
                    "Adjacent runs of one kind are one run; the view draws a Text segment per token."
                )
            }
        }
    }

    @Test("An empty fence is no tokens at all, not one empty token")
    func emptyInput() {
        #expect(CodeHighlighter.tokens(of: "").isEmpty)
    }

    // MARK: - 2. Comments

    @Test("A hash or a double slash starts a comment, and it runs to end of line")
    func commentsAreRecognised() {
        #expect(kinds(of: "timeout-minutes: 15  # criterion 5").contains(.comment))
        #expect(text(ofFirst: .comment, in: "timeout-minutes: 15  # criterion 5") == "# criterion 5")

        #expect(text(ofFirst: .comment, in: "let x = 1 // note") == "// note")
        #expect(text(ofFirst: .comment, in: "# whole line") == "# whole line")
        #expect(text(ofFirst: .comment, in: "#!/usr/bin/env bash") == "#!/usr/bin/env bash")

        // End of line, not end of fence.
        let twoLines = "# first\nlet x = 1\n"
        #expect(text(ofFirst: .comment, in: twoLines) == "# first")
        #expect(kinds(of: twoLines).contains(.keyword))
    }

    /// The three ways a comment cue misfires, all of them present in real
    /// fences in this repository's issues.
    @Test("A URL, a Swift directive and a glued hash are not comments")
    func commentsFailToPlain() {
        #expect(
            !kinds(of: "curl https://example.com/a//b").contains(.comment),
            "The slashes in a URL follow a colon, never whitespace — that is the whole guard."
        )
        #expect(
            !kinds(of: "#if os(macOS)").contains(.comment),
            "`#if` is Swift, not a comment. A `#` is only a comment before whitespace, `!` or `#`."
        )
        #expect(!kinds(of: "#available(macOS 15, *)").contains(.comment))
        #expect(!kinds(of: "let hash = a#b").contains(.comment))
    }

    // MARK: - 3. Strings

    @Test("A matched pair of quotes on one line is a string")
    func stringsAreRecognised() {
        #expect(text(ofFirst: .string, in: "let greeting = \"hello\"") == "\"hello\"")
        #expect(text(ofFirst: .string, in: "branches: [\"main\"]") == "\"main\"")
        #expect(text(ofFirst: .string, in: "echo 'usage'") == "'usage'")
        #expect(text(ofFirst: .string, in: "{\"a\":\"b\"}") == "\"a\"")

        // A double-quoted string carries backslash escapes, so the escaped
        // quote does not close it.
        #expect(text(ofFirst: .string, in: "let s = \"a \\\" quote\"") == "\"a \\\" quote\"")
    }

    @Test("An apostrophe in a word, and a quote that never closes, stay plain")
    func stringsFailToPlain() {
        #expect(
            !kinds(of: "// it's a comment with don't in it").contains(.string),
            "An apostrophe after a letter is not a string opener; it is an apostrophe."
        )
        #expect(!kinds(of: "the shell doesn't mind isn't it").contains(.string))
        #expect(
            !kinds(of: "let unterminated = \"oops").contains(.string),
            "Unterminated is unknown, and unknown is plain — never 'the rest of the fence'."
        )
        // A string cannot span lines, so the second line's quote does not close
        // the first line's.
        #expect(!kinds(of: "\"open\nclose\"").contains(.string))
    }

    @Test("A comment wins over a string it contains, and a string over a hash it contains")
    func cuesResolveLeftToRight() {
        // The `#` comes first, so the quotes inside it are part of the comment.
        #expect(text(ofFirst: .comment, in: "# say \"hello\"") == "# say \"hello\"")
        #expect(!kinds(of: "# say \"hello\"").contains(.string))

        // The quote comes first, so the `#` inside it is part of the string.
        #expect(text(ofFirst: .string, in: "let ref = \"# not a comment\"") == "\"# not a comment\"")
        #expect(!kinds(of: "let ref = \"# not a comment\"").contains(.comment))
    }

    // MARK: - 4. Keywords

    @Test("A keyword matches a whole word and never part of one")
    func keywordsMatchWholeWords() {
        #expect(text(ofFirst: .keyword, in: "let x = 1") == "let")
        #expect(text(ofFirst: .keyword, in: "  return nil") == "return")
        #expect(text(ofFirst: .keyword, in: "\"private\": true") == "true")

        for source in ["iffy = 1", "println(x)", "letter = 2", "doing", "classic"] {
            #expect(
                !kinds(of: source).contains(.keyword),
                "`\(source)` contains a keyword's letters and no keyword."
            )
        }
    }

    @Test("A keyword inside a string or a comment is not a keyword")
    func keywordsDoNotLeakIntoOtherRuns() {
        #expect(!kinds(of: "// let x = 1").contains(.keyword))
        #expect(!kinds(of: "name: \"let it be\"").contains(.keyword))
    }

    /// The list is meant to be words a reader of swift, bash, yaml or json
    /// would call syntax. Commands and library names are neither, and each one
    /// admitted would tint an ordinary word in someone's issue body.
    @Test("The keyword list stays small, lowercase and free of commands")
    func theKeywordListIsDisciplined() {
        #expect(CodeHighlighter.keywords.count < 60)
        for word in CodeHighlighter.keywords {
            #expect(!word.isEmpty)
            #expect(word == word.lowercased())
            #expect(word.allSatisfy { $0.isLetter })
        }
        for command in ["echo", "swift", "git", "curl", "npm", "name", "on", "jobs", "run"] {
            #expect(
                !CodeHighlighter.keywords.contains(command),
                "`\(command)` is a program or a field name, not syntax."
            )
        }
    }

    // MARK: - 5. The mockup's own fence

    /// The approved mockup's YAML block, tokenised. It is here to state plainly
    /// what this implementation does and does not do with it: the comment is
    /// found, and the unquoted keys and scalars stay plain, because tinting a
    /// YAML key like a keyword means knowing the document is YAML — the
    /// per-language grammar this type deliberately does not have.
    @Test("The mockup's YAML fence gets its comment, and guesses at nothing else")
    func theMockupsFence() {
        let yaml = """
            on:
              pull_request:
                branches: [main]
              push:
                branches: [main]
            jobs:
              test:
                runs-on: macos-15
                timeout-minutes: 15          # criterion 5
            """

        let tokens = CodeHighlighter.tokens(of: yaml)
        #expect(tokens.map(\.text).joined() == yaml)

        let comments = tokens.filter { $0.kind == .comment }
        #expect(comments.count == 1)
        #expect(comments.first?.text == "# criterion 5")

        // No quotes anywhere in it, so nothing is a string; no shared keyword
        // in it either. Anything else appearing here would be a guess.
        #expect(!tokens.contains { $0.kind == .string })
        #expect(!tokens.contains { $0.kind == .keyword })
    }

    // MARK: - Helpers

    private func kinds(of source: String) -> Set<CodeTokenKind> {
        Set(CodeHighlighter.tokens(of: source).map(\.kind))
    }

    private func text(ofFirst kind: CodeTokenKind, in source: String) -> String? {
        CodeHighlighter.tokens(of: source).first { $0.kind == kind }?.text
    }
}
