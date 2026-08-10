import Foundation
import Testing

@testable import ElliotAppKit

/// Two claims about the Preflight screen that no behavioural test can reach,
/// read out of the source in the `DrainDuplicationTests` idiom.
///
/// Both are the same shape as the gate #333 had to add one file over: the model
/// is fully tested, the screen renders it, and putting the old expression back
/// leaves every one of those tests green while the screen quietly returns to
/// what it did before.
@Suite("Preflight screen")
struct PreflightScreenTests {

    private static func source() throws -> [String] {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ElliotAppKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ElliotKit
            .appendingPathComponent("Sources/ElliotAppKit/PreflightView.swift")
        // Comments are stripped before matching, for the reason every gate in
        // this repository strips them: the prose around these lines discusses
        // exactly the expressions being looked for.
        return try String(contentsOf: file, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//")
            }
    }

    /// ⛔ An absent reading must reach a sentence, never an empty check list.
    ///
    /// `checkList(model.repoChecks[repo.id] ?? [])` drew *nothing* for a
    /// repository nobody had swept, which is indistinguishable from one whose
    /// every check passed — on the screen whose whole job is to say what is
    /// wrong. `PreflightReading` makes that unsayable in the model; this keeps
    /// the coalescing from coming back one layer up.
    @Test("The screen never turns an absent reading into an empty list of checks")
    func noEmptyStandIn() throws {
        let offenders = try Self.source().enumerated()
            .filter { $0.element.contains("?? []") }
            .map { "line \($0.offset + 1)" }

        #expect(
            offenders.isEmpty,
            """
            PreflightView coalesces a missing reading to an empty collection at \
            \(offenders.joined(separator: ", ")).

            An unread repository then renders exactly like one whose every check \
            passed — the false green #302 removed. Draw \
            `PreflightSummary.unreadLine(isChecking:)` instead, and let the \
            optionality say what it means.
            """
        )
        // And the branch that replaced it is really there.
        #expect(try Self.source().contains { $0.contains("PreflightSummary.unreadLine(") })
    }

    /// ⛔ The badge's destination has to exist.
    ///
    /// `AppModel.openPreflight` sets `preflightFocus` to a repository id and the
    /// screen scrolls to it. Remove the `.id(repo.id)` on the section and every
    /// test of the model stays green while the scroll aims at nothing — the
    /// #159 shape: pure arithmetic, correct, and the decoration never appears.
    @Test("A repository section carries the id a card's badge scrolls to")
    func theSectionIsAScrollTarget() throws {
        #expect(
            try Self.source().contains { $0.contains(".id(repo.id)") },
            """
            No `.id(repo.id)` on Preflight's repository section, so `preflightFocus` \
            names a target that does not exist and pressing a card's `Blocked:` badge \
            unfolds the screen at whatever it was already showing.
            """
        )
    }

    /// The verdict strip's arithmetic lives in `PreflightSummary`, where it is
    /// asserted — including the rule that an unread repository is not a pass.
    /// Re-inlining it here is how the two would disagree.
    @Test("The verdict strip is computed once, in the type that is tested")
    func theSummaryIsNotReinlined() throws {
        #expect(try Self.source().contains { $0.contains("PreflightSummary.of(") })
    }
}
