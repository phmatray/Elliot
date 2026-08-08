import AppKit
import ElliotModel
import Foundation
import SwiftUI
import Testing

@testable import ElliotAppKit

/// What the Repositories page *says* about a verdict.
///
/// Not where the row sits — `swift test` cannot see that, and this project has
/// paid four times for pretending otherwise (#47, #50, #52, #53). What it can
/// see is the vocabulary, and that is precisely what #29 is about: a clone
/// GitHub did not list must not read like one that is fine.
@Suite("Repositories vocabulary")
struct RepositoriesVocabularyTests {

    /// The claim in the issue title, made assertable. Word, symbol and tint are
    /// checked together because any one of them alone would let the row pass for
    /// `.ok` at a glance.
    @Test("An unlisted clone does not read like an ok one")
    func unlistedIsNotSpelledOk() {
        #expect(RepositoriesView.verdict(.unlisted) == "unlisted")
        #expect(RepositoriesView.verdict(.unlisted) != RepositoriesView.verdict(.ok))
        #expect(RepositoriesView.icon(.unlisted) != RepositoriesView.icon(.ok))
    }

    /// Stated as resolved colour rather than as `!=` on `Color`, for the reason
    /// `RunsPaneLiveTests` gives: these are dynamic colours, and comparing them
    /// unresolved compares recipes, not what anyone sees. The second half of the
    /// test is the control — `.ok` *is* the verified tint, so the first half is
    /// not passing because nothing is ever green.
    @MainActor
    @Test("An unlisted clone is not painted in the verified tint")
    func unlistedIsNotGreen() throws {
        let appearance = try #require(NSAppearance(named: .aqua))
        let verified = try #require(Self.srgb(Palette.verified, in: appearance))

        let unlisted = try #require(Self.srgb(RepositoriesView.tint(.unlisted), in: appearance))
        #expect(unlisted != verified, "an unconfirmed repository drew in the verified tint")

        #expect(try #require(Self.srgb(RepositoriesView.tint(.ok), in: appearance)) == verified)
    }

    /// Every verdict says something, and every symbol it names actually exists.
    ///
    /// Exhaustiveness is the compiler's job — the switches carry no `default:` —
    /// but a case answering with an empty string, or with an SF Symbol that was
    /// never shipped, compiles and tests green and then draws **nothing** where
    /// the status icon should be. That is the class of bug this project has
    /// repeatedly had to *look* at the window to find; here it is cheap enough
    /// to assert instead.
    @MainActor
    @Test("Every verdict has a word, and a symbol that resolves")
    func vocabularyIsTotal() {
        for issue in Self.everyIssue {
            #expect(!RepositoriesView.verdict(issue).isEmpty)
            let name = RepositoriesView.icon(issue)
            #expect(!name.isEmpty)
            #expect(
                NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                "\(issue) names \(name), which is not an SF Symbol on this system")
        }
        // And no two verdicts share a word, or the page would merge two answers.
        #expect(Set(Self.everyIssue.map(RepositoriesView.verdict)).count == Self.everyIssue.count)
    }

    /// One of each case. A verdict added to `RepoIssue` fails to compile in the
    /// view's switches, which is the real guard; this list is what makes the
    /// same addition visible *here*, where the word and symbol get checked.
    private static let everyIssue: [RepoIssue] = [
        .ok, .notCloned, .notRegistered, .missing, .misplaced(expected: "/R/x"),
        .unlisted, .outOfScope(.fork), .outOfScope(.archived), .outOfScope(.empty),
        .outOfScope(.otherRoot),
        .behind(by: 3), .dirty, .ahead, .diverged, .detached, .noRemote, .unreadable("no HEAD"),
    ]

    // MARK: - The summary sentence

    /// The row-level fix is worth nothing if the sentence above it still says
    /// everything is fine. An unlisted row has no fix, so it cannot ride on the
    /// "needs attention" count — it has to be counted on its own.
    @Test("An unlisted repository is not swallowed by 'nothing needs attention'")
    func summaryCountsUnlisted() {
        let rows = [Self.row("phmatray/Koine", .unlisted), Self.row("phmatray/Ducky", .ok)]
        #expect(RepositoriesView.clauses(for: rows) == ["1 unlisted"])
    }

    @Test("Attention and unlisted are counted separately, in that order")
    func summaryCountsBoth() {
        let rows = [
            Self.row("phmatray/Koine", .unlisted),
            Self.row("phmatray/Ducky", .unlisted),
            Self.row(
                "phmatray/Yendor", .notCloned,
                fixes: [.clone(nameWithOwner: "phmatray/Yendor", into: "/R/y")]),
        ]
        #expect(RepositoriesView.clauses(for: rows) == ["1 needs attention", "2 unlisted"])
    }

    /// The wording nothing else may drift away from: with every row settled, the
    /// sentence is still allowed to say so.
    @Test("With nothing unlisted and nothing to fix, the sentence still says so")
    func summarySaysNothingWhenNothingIsWrong() {
        let settled = [Self.row("phmatray/Koine", .ok)]
        #expect(RepositoriesView.clauses(for: settled) == ["nothing needs attention"])
        #expect(RepositoriesView.clauses(for: []) == ["nothing needs attention"])
    }

    // MARK: - Helpers

    private static func row(
        _ nameWithOwner: String, _ issue: RepoIssue, fixes: [RepoFix] = []
    ) -> RepoRow {
        RepoRow(id: nameWithOwner, nameWithOwner: nameWithOwner, issue: issue, fixes: fixes)
    }

    private static func srgb(_ color: Color, in appearance: NSAppearance) -> [CGFloat]? {
        var out: [CGFloat]?
        appearance.performAsCurrentDrawingAppearance {
            guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            out = [srgb.redComponent, srgb.greenComponent, srgb.blueComponent]
        }
        return out
    }
}
