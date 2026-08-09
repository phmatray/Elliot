import Foundation
import Testing

/// The analysis screens may not ask the board's toolbar picker which repository
/// they are about (#213).
///
/// The behavioural tests in `AnalysisRepoScopeTests` prove the **rule**; this
/// one pins the **shape**, and the shape is what the next feature undoes without
/// noticing — by adding a sub-view that reaches for `model.selectedRepoID`
/// because that is what the file used to do. Nothing would fail: the new view
/// would render the picked repository, which is right in setup and wrong for
/// every open analysis, and no test asserts about a view that does not exist
/// yet.
///
/// The idiom is the one `DrainDuplicationTests` and `CaretAnchorTests` already
/// use here, for the reason `CLAUDE.md` states: *a gate that is not a test is a
/// gate nobody re-runs.*
@Suite("The analysis panel's source")
struct AnalysisPanelViewSourceTests {

    /// Where the views live, found from this file rather than from the working
    /// directory — `swift test` promises nothing about the latter.
    private static var viewSources: URL {
        URL(filePath: #filePath)          // …/Tests/ElliotAppKitTests/<this file>
            .deletingLastPathComponent()  // …/Tests/ElliotAppKitTests
            .deletingLastPathComponent()  // …/Tests
            .deletingLastPathComponent()  // …/ElliotKit
            .appending(path: "Sources/ElliotAppKit")
    }

    /// Every `Analysis*.swift` under `Sources/ElliotAppKit`, rather than the one
    /// file the defect was found in.
    ///
    /// Discovered rather than listed, so a sub-view split out of the panel
    /// tomorrow is covered on the day it is created — which is the only day the
    /// mistake is easy to make.
    private static func analysisSources() throws -> [(name: String, source: String)] {
        let directory = viewSources
        let names = try FileManager.default
            .contentsOfDirectory(atPath: directory.path(percentEncoded: false))
            .filter { $0.hasPrefix("Analysis") && $0.hasSuffix(".swift") }
            .sorted()
        return try names.map {
            ($0, try String(contentsOf: directory.appending(path: $0), encoding: .utf8))
        }
    }

    /// The line with any `//` comment removed.
    ///
    /// ⚠️ **Load-bearing, and the trap this kind of test walks into.** Both
    /// `AnalysisPanelView` and `AnalysisSession` *document* why they do not read
    /// the picker, naming it — so a gate that matched raw text would fail on the
    /// explanation of the very rule it enforces, and the obvious way to make it
    /// pass would be to delete the explanation. `CLAUDE.md` records the same
    /// hazard from #186: a string gate over prose *"can tell neither a claim
    /// from a mention nor a live claim from a quoted one"*. Cutting at `//`
    /// tells them apart for this file set, where no string literal contains one.
    private static func code(_ line: String) -> String {
        guard let comment = line.range(of: "//") else { return line }
        return String(line[line.startIndex..<comment.lowerBound])
    }

    @Test("No analysis screen resolves its repository from the board's picker")
    func thePickerIsNotTheSubject() throws {
        let files = try Self.analysisSources()

        // A negative needs its positive witness: an empty file set, or a
        // renamed panel, would make every claim below vacuously true and this
        // suite would go green having read nothing.
        #expect(!files.isEmpty, "found no Analysis*.swift under Sources/ElliotAppKit")
        #expect(
            files.contains { $0.name == "AnalysisPanelView.swift" },
            """
            AnalysisPanelView.swift was not among \(files.map(\.name)) — this gate is reading the \
            wrong directory, or the panel has been renamed and the guard has silently stopped \
            covering it
            """
        )

        for file in files {
            let offenders = file.source
                .components(separatedBy: "\n")
                .enumerated()
                .filter { Self.code($0.element).contains("selectedRepoID") }
                .map { "\(file.name):\($0.offset + 1): \($0.element.trimmingCharacters(in: .whitespaces))" }

            #expect(
                offenders.isEmpty,
                """
                an analysis screen is asking the board's toolbar picker which repository it is \
                about. That is what the reader is filtering the columns by; it says nothing about \
                which repository the open analysis read, and it can move while the panel is on \
                screen. The subject belongs to AnalysisSession.repoID — read AppModel.analysisRepo \
                or AppModel.analysisRepoID instead (#213). Sites: \(offenders.joined(separator: " · "))
                """
            )
        }
    }

    // MARK: - Where the Rejected disclosure sits

    /// `AnalysisPanelView.swift` with every `//` comment cut away, so a *mention*
    /// of a token cannot be read as a use of it — the same hazard the `code(_:)`
    /// helper above exists for, and the one CLAUDE.md records from #186.
    private static func panelCode() throws -> String {
        let source = try String(
            contentsOf: viewSources.appending(path: "AnalysisPanelView.swift"), encoding: .utf8)
        return source.components(separatedBy: "\n").map(code).joined(separator: "\n")
    }

    /// The body of one function, by brace matching from its signature.
    ///
    /// ⚠️ **Brace counting is only honest because the function it is pointed at
    /// holds no braces inside string literals**, which `proposalList` does not —
    /// its strings all live in the helpers it calls. Scoped to one function
    /// rather than run over the file for exactly that reason.
    private static func body(of signature: String, in source: String) throws -> String {
        let start = try #require(source.range(of: signature))
        var depth = 0
        var open: String.Index?
        var index = start.upperBound
        while index < source.endIndex {
            if source[index] == "{" {
                if depth == 0 { open = source.index(after: index) }
                depth += 1
            } else if source[index] == "}" {
                depth -= 1
                if depth == 0, let open { return String(source[open..<index]) }
            }
            index = source.index(after: index)
        }
        Issue.record("no matching brace for \(signature)")
        return ""
    }

    /// How deep in braces a token sits inside a body.
    private static func depth(of token: String, in body: String) throws -> Int {
        let range = try #require(
            body.range(of: token), Comment(rawValue: "\(token) is not in the body being read"))
        return body[body.startIndex..<range.lowerBound].reduce(into: 0) { depth, character in
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
        }
    }

    // MARK: - A lens you cannot untick

    /// ⛔ **A tile marked busy is still tickable.**
    ///
    /// #151 removed a `.disabled` from the Analyse toggle on the argument that a
    /// control you cannot switch off is worse than one that opens onto an
    /// explanation, and a lens you cannot untick is that trap one screen in —
    /// unticking it is the reader's *whole* remedy for a clash. It is worse
    /// here than there: `busy` comes from a snapshot and can be wrong in both
    /// directions, so a disabled tile takes a control away on the strength of a
    /// hint (#293).
    ///
    /// A source gate for the reason `CLAUDE.md` gives — `swift test` cannot see
    /// a view, so a `.disabled(model.lensBusy(angle) != nil)` added here would
    /// leave every other test in this file green while the grid quietly stopped
    /// accepting a click.
    @Test("A busy lens tile can still be ticked — nothing in it is disabled")
    func theLensTileIsNeverDisabled() throws {
        let body = try Self.body(of: "struct LensTile: View", in: try Self.panelCode())

        // A negative needs its positive witness: a renamed or restructured tile
        // would make the claim below vacuously true.
        #expect(
            body.contains("Button(action: toggle)"),
            "LensTile no longer wraps its content in the toggle button this gate is about")

        #expect(
            !body.contains(".disabled("),
            """
            LensTile carries a `.disabled(…)`. A lens the reader cannot untick is the trap #151 \
            removed from the Analyse toggle, and here the value driving it is a snapshot that can \
            be wrong — `AnalysisService.start` is the authority, the seal is a hint (#293).
            """)
    }

    /// ⛔ **The grid asks the model which lenses are busy.**
    ///
    /// `busy:` has no default, so *forgetting* it is a compile error — what this
    /// pins is the step after that: a call site passing `nil`, or reaching for
    /// the store itself and doing its own repository scoping. `AppModel.lensBusy`
    /// is where the scoping lives (`BusyLenses` refuses to answer about a
    /// repository it was not read for), and a view that re-derived it would be
    /// free to re-derive it wrongly.
    ///
    /// The gap this closes is the one `CaretAnchorTests` was written for: the
    /// arithmetic either side is pinned, and the *step between* — three values
    /// reaching one reader — had no test at all, so everything stayed green
    /// while nothing appeared on screen.
    @Test("The lens grid asks the model whether each lens is already reading")
    func theGridAsksWhichLensesAreBusy() throws {
        let source = try Self.panelCode()

        #expect(source.contains("LensTile("), "the setup grid no longer builds a LensTile")
        #expect(
            source.contains("busy: model.lensBusy("),
            """
            no LensTile is being handed AppModel.lensBusy(_:). Passing `nil`, or asking the store \
            directly, loses the repository scoping that stops one repository's reading being drawn \
            under another's header (#213's axis, #293).
            """)
    }

    // MARK: - The bulk selections select; they do not decide

    /// ⛔ **The duplicate hint is a courtesy, so the bar that acts on it in bulk
    /// may only *select*.**
    ///
    /// `StoryProposal.duplicateOf` says in as many words that skipping a
    /// near-duplicate is the reader's call, and the flag behind it is a
    /// `TextSimilarity` score over two short titles at a threshold of 0.6 —
    /// nowhere near good enough to reject on. *Reject the N flagged* would be
    /// one keystroke that turns eight lenses' worth of hints into decisions,
    /// with the rows gone before anyone read them (#295).
    ///
    /// A source gate because `swift test` cannot press a button: swapping
    /// `analysisSelection = Set(flagged)` for `rejectProposals(ids: flagged)`
    /// leaves every other test in this file green.
    @Test("The selection bar selects the flagged rows; it never decides them")
    func theBulkDuplicateActionOnlySelects() throws {
        let bar = try Self.body(of: "private func selectionBar(", in: try Self.panelCode())

        // Positive witnesses: the bar still offers both bulk selections, so the
        // negative below is about what they do rather than about a renamed
        // helper.
        #expect(bar.contains("filter(\\.isGrounded)"), "the grounded selection has gone")
        #expect(
            bar.contains("filter(\\.looksDuplicated)"),
            "the selection bar no longer offers the flagged rows in one gesture (#295)")

        for verb in ["rejectProposals", "acceptProposals"] {
            #expect(
                !bar.contains(verb),
                Comment(
                    rawValue:
                        "the selection bar calls \(verb). It stages rows for the footer's Accept "
                        + "and Reject; deciding them here makes a hint into a refusal, on a 0.6 "
                        + "similarity score (#295)."))
        }
    }

    /// ⛔ **The rejected disclosure is a sibling of `if proposed.isEmpty`, never
    /// inside its `else`.**
    ///
    /// The state the section exists for is *"I rejected the wrong one"* — and
    /// rejecting the last open proposal empties the triage list, so a section
    /// nested under `!proposed.isEmpty` would hide the undo in precisely the
    /// case that needs it most while looking perfectly correct in every case
    /// anyone would think to try (#292).
    ///
    /// A source gate because `swift test` cannot see a view: the arithmetic, the
    /// filter and the store's refusal are all pinned by ordinary tests and every
    /// one of them stays green with the call moved one level in. This is the
    /// idiom `CaretAnchorTests` reaches for on the same grounds — when a test
    /// builds its own model of the code, ask what it would say if the code
    /// changed underneath it, and if the answer is "nothing", pin the shape
    /// where the shape lives.
    @Test("The rejected disclosure renders whether or not anything is left to decide")
    func theUndoIsNotHiddenByAnEmptyList() throws {
        let body = try Self.body(of: "private func proposalList(", in: try Self.panelCode())
        // A negative needs its positive witness: a renamed helper would make
        // every claim below vacuously true.
        #expect(body.contains("rejectedSection("), "proposalList no longer renders the disclosure")

        let branch = try Self.depth(of: "if proposed.isEmpty", in: body)
        let disclosure = try Self.depth(of: "rejectedSection(", in: body)
        #expect(
            disclosure == branch,
            Comment(
                rawValue:
                    "rejectedSection sits \(disclosure - branch) brace level(s) deeper than the "
                    + "`if proposed.isEmpty` it must be a sibling of. Inside that branch it "
                    + "disappears exactly when every proposal has been rejected — which is when "
                    + "the reader needs it (#292)."))
    }
}
