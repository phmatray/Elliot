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

    // MARK: - 1b. The declaration

    @Test("A declaration this type has no rules for changes nothing at all")
    func anUnrecognisedDeclarationIsInert() {
        // The default path is the contract: a fence declared `rust` must render
        // exactly as an undeclared one, because this type has no rust rules and
        // the nearest rules it does have would be a guess. Criterion 2 lives
        // here — swift, bash and json fences are named explicitly.
        let languages: [String?] = [nil, "", "   ", "swift", "bash", "sh", "json", "text", "Rust"]
        for source in corpus {
            let agnostic = CodeHighlighter.tokens(of: source)
            for language in languages {
                #expect(
                    CodeHighlighter.tokens(of: source, language: language) == agnostic,
                    "declaring `\(language ?? "nil")` moved a token in \(source.debugDescription)"
                )
            }
        }
    }

    @Test("The declaration is read from the first word, and case does not matter")
    func dialectReadsTheInfoString() {
        // CommonMark lets the info string carry more than the language, and this
        // repository's own mockup writes ```yaml .github/workflows/ci.yml.
        #expect(CodeHighlighter.Dialect(declared: "yaml") == .yaml)
        #expect(CodeHighlighter.Dialect(declared: "yml") == .yaml)
        #expect(CodeHighlighter.Dialect(declared: "YAML") == .yaml)
        #expect(CodeHighlighter.Dialect(declared: "yaml .github/workflows/ci.yml") == .yaml)

        #expect(CodeHighlighter.Dialect(declared: nil) == .agnostic)
        #expect(CodeHighlighter.Dialect(declared: "") == .agnostic)
        // Near misses are not near enough. `yamlish` is not yaml, and a type
        // that matched on a prefix would be guessing again.
        #expect(CodeHighlighter.Dialect(declared: "yamlish") == .agnostic)
        #expect(CodeHighlighter.Dialect(declared: "swift") == .agnostic)
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

    // MARK: - 6. A fence the author declared to be YAML

    @Test("A key is a keyword, indentation and the colon are not")
    func yamlKeysAreKeywords() {
        #expect(yamlText(ofFirst: .keyword, in: "on:") == "on")
        #expect(yamlText(ofFirst: .keyword, in: "  pull_request:") == "pull_request")
        // Hyphens belong to the key. `runs` alone would be a different field.
        #expect(yamlText(ofFirst: .keyword, in: "    runs-on: macos-15") == "runs-on")
        #expect(yamlText(ofFirst: .keyword, in: "    timeout-minutes: 15") == "timeout-minutes")
        // A mapping inside a sequence, which is most of the YAML in this repo.
        #expect(yamlText(ofFirst: .keyword, in: "  - uses: actions/checkout@v4") == "uses")

        // The colon and the indentation are structure and stay plain, or the
        // whole line would read as one tinted blob.
        let tokens = CodeHighlighter.tokens(of: "  push:", language: "yaml")
        #expect(tokens.map(\.text) == ["  ", "push", ":"])
        #expect(tokens.map(\.kind) == [.plain, .keyword, .plain])
    }

    @Test("A colon that opens nothing is not a key")
    func yamlKeysFailToPlain() {
        // The same guard as the comment rule, one cue over: what follows the
        // colon decides. A URL is the case that would be wrong every time.
        #expect(
            !yamlKinds(of: "https://example.com").contains(.keyword),
            "`https` is not a key — its colon is followed by a slash, not a space."
        )
        #expect(
            !yamlKinds(of: "a:b").contains(.keyword),
            "`a:b` is YAML's scalar `a:b`, not a mapping."
        )
        #expect(!yamlKinds(of: ": leading colon").contains(.keyword))
        #expect(!yamlKinds(of: "# just a comment").contains(.keyword))
        #expect(!yamlKinds(of: "").contains(.keyword))
    }

    @Test("An unquoted scalar is a string, and flow punctuation stays plain")
    func yamlScalarsAreStrings() {
        #expect(yamlText(ofFirst: .string, in: "    runs-on: macos-15") == "macos-15")
        #expect(yamlText(ofFirst: .string, in: "    timeout-minutes: 15") == "15")
        #expect(yamlText(ofFirst: .string, in: "    branches: [main]") == "main")

        // The brackets are structure. Tinting them would make a list look like
        // a value called "[main]".
        // The colon, the space and the bracket are one plain run: adjacent runs
        // of a kind are merged, which is what `tokensAreMinimalRuns` requires.
        let flow = CodeHighlighter.tokens(of: "branches: [main]", language: "yaml")
        #expect(flow.map(\.text) == ["branches", ": [", "main", "]"])
        #expect(flow.map(\.kind) == [.keyword, .plain, .string, .plain])

        // A bare sequence item is a scalar with no key.
        #expect(yamlText(ofFirst: .string, in: "  - macos-15") == "macos-15")
        // A key with no value tints nothing beyond the key.
        #expect(!yamlKinds(of: "jobs:").contains(.string))
    }

    /// The approved mockup's own fence, asserted against
    /// `docs/mockups/inline-detail-panel.html` lines 655–665 span for span.
    /// That block is the design this feature exists to match, so it is checked
    /// token for token rather than by sampling.
    @Test("The mockup's YAML fence comes out exactly as the mockup draws it")
    func theMockupsFenceDeclaredAsYAML() {
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

        let tokens = CodeHighlighter.tokens(of: yaml, language: "yaml")
        #expect(tokens.map(\.text).joined() == yaml)

        // <span class="k"> in the mockup, in document order.
        let keywords = tokens.filter { $0.kind == .keyword }.map(\.text)
        #expect(keywords == [
            "on", "pull_request", "branches", "push", "branches",
            "jobs", "test", "runs-on", "timeout-minutes",
        ])

        // <span class="s">, in document order.
        let strings = tokens.filter { $0.kind == .string }.map(\.text)
        #expect(strings == ["main", "main", "macos-15", "15"])

        // <span class="c">, and still exactly the one.
        let comments = tokens.filter { $0.kind == .comment }.map(\.text)
        #expect(comments == ["# criterion 5"])
    }

    @Test("Declaring YAML does not weaken a single one of the refusals")
    func yamlKeepsEveryNegative() {
        // Criterion 3. These four are the reasons this type has no grammar, and
        // a per-language cue set is only safe while they still hold.
        #expect(!yamlKinds(of: "curl https://example.com/a//b").contains(.comment))
        #expect(!yamlKinds(of: "#if os(macOS)").contains(.comment))
        #expect(!yamlKinds(of: "note: the shell doesn't mind").contains(.comment))
        #expect(
            yamlText(ofFirst: .string, in: "note: the shell doesn't mind") == "the",
            "An apostrophe mid-word is part of the scalar, never a quote that opens one."
        )
        #expect(
            !yamlKinds(of: "let unterminated = \"oops").contains(.string),
            "An unterminated quote is unknown, and unknown is plain."
        )
        // A quoted scalar is still the quoted run, not two half-scalars.
        #expect(yamlText(ofFirst: .string, in: "name: \"hello world\"") == "\"hello world\"")
        // And a comment still wins over what it contains.
        #expect(yamlText(ofFirst: .comment, in: "key: v  # say \"hi\"") == "# say \"hi\"")
    }

    @Test("Totality holds for every declaration, not only the default")
    func nothingIsDroppedInAnyDialect() {
        // Criterion 4, restated across the axis this change added. A per-line
        // branch is exactly where a character goes missing.
        let languages: [String?] = [nil, "yaml", "yml", "YAML", "swift", "json"]
        for source in corpus + yamlCorpus {
            for language in languages {
                let tokens = CodeHighlighter.tokens(of: source, language: language)
                #expect(
                    tokens.map(\.text).joined() == source,
                    "`\(language ?? "nil")` dropped a character from \(source.debugDescription)"
                )
                for token in tokens {
                    #expect(!token.text.isEmpty)
                }
                for (left, right) in zip(tokens, tokens.dropFirst()) {
                    #expect(left.kind != right.kind, "\(language ?? "nil"): adjacent runs of one kind")
                }
            }
        }
    }

    /// Awkward YAML, so the totality property above runs against the shapes the
    /// new branch actually has to survive rather than against tidy ones.
    private let yamlCorpus: [String] = [
        "on:",
        ":",
        "-",
        "- ",
        "  -   spaced: value",
        "a:b",
        "https://example.com",
        "key: [a, b, {c: d}]",
        "key: 'single'  # and a comment",
        "key:\tvalue",
        "  key: \"unterminated",
        "ключ: значение",
        "key: don't",
        "key:",
        "   ",
    ]

    // MARK: - Helpers

    private func kinds(of source: String) -> Set<CodeTokenKind> {
        Set(CodeHighlighter.tokens(of: source).map(\.kind))
    }

    private func text(ofFirst kind: CodeTokenKind, in source: String) -> String? {
        CodeHighlighter.tokens(of: source).first { $0.kind == kind }?.text
    }

    private func yamlKinds(of source: String) -> Set<CodeTokenKind> {
        Set(CodeHighlighter.tokens(of: source, language: "yaml").map(\.kind))
    }

    private func yamlText(ofFirst kind: CodeTokenKind, in source: String) -> String? {
        CodeHighlighter.tokens(of: source, language: "yaml").first { $0.kind == kind }?.text
    }
}
