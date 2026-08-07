import Foundation
import Testing

@testable import ElliotAppKit

/// One field set behind both editors, and a guard that says so tomorrow.
///
/// `ProposalEditor` was a second implementation of `CardFieldsEditor` for three
/// months, and the cost was not the duplication itself but what happened to it:
/// `CardDraft.removeCriterion` gained its index guard in `f78a395` and the
/// second copy was written *unguarded* in `c1136b1`, one day later and one file
/// over. A fix existed and did not travel.
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
    private static func sources() throws -> [(name: String, lines: [String])] {
        let directory = viewSources
        let names = try FileManager.default
            .contentsOfDirectory(atPath: directory.path(percentEncoded: false))
            .filter { $0.hasSuffix(".swift") }
            .sorted()

        return try names.map { name in
            let text = try String(
                contentsOf: directory.appending(path: name), encoding: .utf8
            )
            return (name, text.components(separatedBy: "\n"))
        }
    }

    /// A comment that *mentions* a construct is prose, not the construct.
    ///
    /// Both scans below skip comment lines, as `BoardAccessibilityTests` does.
    /// Without it this suite would fail on the doc comments that explain why it
    /// exists — including the ones above — which is an absurd way for a guard
    /// to go red.
    private static func isComment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*")
    }

    private static func sites(matching needle: String) throws -> [String] {
        try sources().flatMap { file in
            file.lines.enumerated()
                .filter { !isComment($0.element) && $0.element.contains(needle) }
                .map { "\(file.name):\($0.offset + 1)" }
        }
    }

    @Test("The story-field helper is declared exactly once")
    func oneFieldHelper() throws {
        let sites = try Self.sites(matching: "func field(_ label: String, placeholder:")
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
    func noUnguardedRemoval() throws {
        let sites = try Self.sites(matching: "criteria.remove(at:")
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
    func oneBoardLabelField() throws {
        let sites = try Self.sites(matching: "TextField(\"Short name for the card\"")
        #expect(
            sites.count == 1,
            """
            The board-label row belongs to CardFieldsEditor. Found \(sites.count) \
            copies: \(sites.joined(separator: ", ")).
            """
        )
    }

    /// A scan that finds nothing because it is looking in the wrong place is a
    /// guard that passes for ever. This is the control: the directory resolves,
    /// it holds the views, and `AnalysisWindow.swift` — the file that carried
    /// the second copy — is among the files actually read.
    @Test("The scan is reading the real sources")
    func theScanReadsSomething() throws {
        let files = try Self.sources()
        #expect(files.count > 10, "found only \(files.count) source files")
        #expect(files.contains { $0.name == "AnalysisWindow.swift" })
        #expect(files.contains { $0.name == "CardFieldsEditor.swift" })
    }
}
