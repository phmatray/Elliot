import Foundation
import Testing

@testable import ElliotAppKit

/// One field set behind both editors, and a guard that says so tomorrow.
///
/// `ProposalEditor` was a second implementation of `CardFieldsEditor`, and the
/// cost was not the duplication itself but what happened to it:
/// `CardDraft.removeCriterion` gained its index guard in `f78a395`
/// (2026-08-05 17:33) and the second copy was written *unguarded* in `c1136b1`
/// (2026-08-05 23:18) — **the same day, five hours and forty-five minutes
/// later**, one file over. A fix existed, in this repository, and did not
/// travel across a single evening.
///
/// The interval is the point, and it is why this guard is mechanical rather
/// than a note asking for care: duplication does not need months to diverge.
/// (An earlier draft of this comment said "three months" and "one day later".
/// Both were invented; `git log` says otherwise, and this repository's own
/// rule is that a comment is not a measurement.)
///
/// So the thing worth holding is not "the helper exists once today" — #147 did
/// that — but that a third copy cannot appear without a red bar. This suite
/// scans the sources the way `BoardAccessibilityTests`, `CardAngleMarkTests`
/// and `RepositoriesSweepReportTests` already do: what `swift test` cannot see
/// on screen, it can still see in the text.
@Suite("Story fields live in one place")
struct EditorFieldSharingTests {

    /// Where the views live, found from this file rather than from the working
    /// directory — `swift test` promises nothing about the latter.
    private static var viewSources: URL {
        URL(filePath: #filePath)          // …/Tests/ElliotAppKitTests/<this file>
            .deletingLastPathComponent()  // …/Tests/ElliotAppKitTests
            .deletingLastPathComponent()  // …/Tests
            .deletingLastPathComponent()  // …/ElliotKit
            .appending(path: "Sources/ElliotAppKit")
    }

    /// Every `.swift` file under `Sources/ElliotAppKit`, as (name, lines).
    ///
    /// Read once for the whole suite rather than once per needle: the
    /// directory is 27 files and some 12 000 lines, and four scans of it to
    /// answer four questions is three walks nobody asked for.
    private static let sources: [(name: String, lines: [String])] = {
        let directory = viewSources
        guard let names = try? FileManager.default
            .contentsOfDirectory(atPath: directory.path(percentEncoded: false))
            .filter({ $0.hasSuffix(".swift") })
            .sorted()
        else { return [] }

        return names.compactMap { name in
            guard let text = try? String(
                contentsOf: directory.appending(path: name), encoding: .utf8
            ) else { return nil }
            return (name, text.components(separatedBy: "\n"))
        }
    }()

    /// The code on a line, with any trailing comment removed.
    ///
    /// A comment that *mentions* a construct is prose, not the construct — and
    /// the comment that mentions it is usually **trailing**, which is the shape
    /// this codebase writes. Dropping only whole-line comments (which is what
    /// this did at first) would let
    /// `draft.removeCriterion(at: index)  // was criteria.remove(at: index)`
    /// redden the guard: the note explaining the fix would be read as the
    /// defect. Splitting on `//` is crude — it would also cut a `//` inside a
    /// string literal — but none of the needles below can occur after one.
    private static func code(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { return "" }
        guard let comment = line.range(of: "//") else { return line }
        return String(line[..<comment.lowerBound])
    }

    private static func sites(matching needle: String) -> [String] {
        sources.flatMap { file in
            file.lines.enumerated()
                .filter { code($0.element).contains(needle) }
                .map { "\(file.name):\($0.offset + 1)" }
        }
    }

    @Test("The story-field helper is declared exactly once")
    func oneFieldHelper() {
        let sites = Self.sites(matching: "func field(_ label: String, placeholder:")
        #expect(
            sites.count == 1,
            """
            `field(_:placeholder:text:)` must be declared once — it belongs to \
            CardFieldsEditor, and every editor of these three rows is a caller \
            of that view rather than a second copy of it. Found \(sites.count) \
            declaration(s): \(sites.joined(separator: ", ")).
            """
        )
    }

    /// The guarded removal is `CardDraft.removeCriterion`, and it is guarded
    /// for a reason the view layer cannot see: `ForEach(indices, id: \.self)`
    /// can hand back a row that is already gone, and a bare `remove(at:)` on
    /// that index traps. A view that removes a criterion itself is a view that
    /// has re-derived the rule — which is how the crash guard failed to travel
    /// the first time.
    @Test("No view removes a criterion by hand")
    func noUnguardedRemoval() {
        let sites = Self.sites(matching: "criteria.remove(at:")
        #expect(
            sites.isEmpty,
            """
            Dropping a criterion goes through `CardDraft.removeCriterion`, which \
            checks the index; `ForEach(indices, id: \\.self)` can hand back a row \
            that is already gone, and a bare remove on it traps. Found \
            \(sites.count) hand-rolled removal(s): \(sites.joined(separator: ", ")).
            """
        )
    }

    /// The board label was duplicated alongside the helper, and it is the part
    /// that would come back first: it is three lines, it looks harmless, and
    /// nothing about it says "this exists elsewhere".
    @Test("The board-label field is written once")
    func oneBoardLabelField() {
        let sites = Self.sites(matching: "TextField(\"Short name for the card\"")
        #expect(
            sites.count == 1,
            """
            The board-label row belongs to CardFieldsEditor. Found \(sites.count) \
            copies: \(sites.joined(separator: ", ")).
            """
        )
    }

    /// The story/note picker is the one control that can undo the whole design.
    ///
    /// `.story` is safe because `CardDraft(proposal:)` pins `isStory` and
    /// `CardFieldsEditor` re-pins it on appear — but the picker is what would
    /// *un*-pin it, and it is one deleted `if` away from being unconditional.
    /// Delete that line and the full suite still passed before this test
    /// existed: nothing else in `ElliotAppKitTests` touches this view. The
    /// proposal editor would then show a "Plain note" picker, selecting it
    /// would weaken `isValid` to "the label is non-blank", and Save would
    /// discard the story — which is precisely the outcome issue #147 rejected
    /// approach C for.
    ///
    /// Modelled on `BoardAccessibilityTests.answersToReduceMotion`, which
    /// checks a site's *preamble* rather than the site alone.
    @Test("The story/note picker stays behind the card kind")
    func pickerIsGatedOnCardKind() {
        let files = Self.sources.filter { $0.name == "CardFieldsEditor.swift" }
        #expect(files.count == 1, "CardFieldsEditor.swift was not found")

        for file in files {
            guard let index = file.lines.firstIndex(where: {
                Self.code($0).contains("Picker(\"\", selection: $draft.isStory)")
            }) else {
                Issue.record("the story/note picker was not found — has it been renamed?")
                continue
            }

            // The gate is the nearest preceding `if`, within a few lines.
            let preamble = file.lines[max(0, index - 4)..<index].map(Self.code)
            #expect(
                preamble.contains { $0.contains("kind == .card") },
                """
                The story/note picker must sit inside `if kind == .card`. \
                Ungated, a `.story` editor offers a mode `StoryProposal` cannot \
                store, and Save silently drops the story. Preamble was: \
                \(preamble.map { $0.trimmingCharacters(in: .whitespaces) })
                """
            )
        }
    }

    /// A scan that finds nothing because it is looking in the wrong place is a
    /// guard that passes for ever. This is the control: the directory resolves,
    /// it holds the views, and `AnalysisPanelView.swift` — the file that carried
    /// the second copy — is among the files actually read.
    ///
    /// It was `AnalysisWindow.swift` when this suite was written, and #151
    /// renamed it while this branch sat open. The control caught its own
    /// rename, which is the whole reason to name a file here rather than
    /// trust `files.count`: had this only counted, the suite would have stayed
    /// green while pointing at a directory that no longer held the file the
    /// other three tests exist to watch.
    @Test("The scan is reading the real sources")
    func theScanReadsSomething() {
        let files = Self.sources
        #expect(files.count > 10, "found only \(files.count) source files")
        #expect(files.contains { $0.name == "AnalysisPanelView.swift" })
        #expect(files.contains { $0.name == "CardFieldsEditor.swift" })
    }
}
