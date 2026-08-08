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
        .unlisted, .notChecked, .outOfScope(.fork), .outOfScope(.archived),
        .outOfScope(.otherRoot),
        .behind(by: 3), .dirty, .ahead, .diverged, .detached, .noRemote, .unreadable("no HEAD"),
    ]

    // MARK: - A listing that never arrived (#148)

    /// `.unlisted` and `.notChecked` are the two halves of GitHub's silence, and
    /// the page has to keep them apart with the word and the symbol alone: they
    /// share `Palette.attention`, because a sixth accent is a design decision
    /// rather than a merge (`BrandColorTests` pins five).
    ///
    /// The `.ok` half of the claim is the one that matters most — an unread
    /// repository drawn as a green tick is the non-measurement-as-a-pass this
    /// whole issue is about.
    @Test("A repository nobody could check reads like neither ok nor unlisted")
    func notCheckedIsItsOwnWord() {
        #expect(RepositoriesView.verdict(.notChecked) == "not checked")
        #expect(RepositoriesView.verdict(.notChecked) != RepositoriesView.verdict(.ok))
        #expect(RepositoriesView.verdict(.notChecked) != RepositoriesView.verdict(.unlisted))
        #expect(RepositoriesView.icon(.notChecked) != RepositoriesView.icon(.ok))
        #expect(RepositoriesView.icon(.notChecked) != RepositoriesView.icon(.unlisted))
    }

    @MainActor
    @Test("A repository nobody could check is not painted in the verified tint")
    func notCheckedIsNotGreen() throws {
        let appearance = try #require(NSAppearance(named: .aqua))
        let verified = try #require(Self.srgb(Palette.verified, in: appearance))
        let notChecked = try #require(Self.srgb(RepositoriesView.tint(.notChecked), in: appearance))
        #expect(notChecked != verified)
    }

    // MARK: - What a probed not-checked row can read as (#189)

    /// Since #189 a `.notChecked` row is probed, so the page has to have a word
    /// and a symbol for every verdict that probe can leave it in — not just for
    /// `.notChecked` itself.
    ///
    /// The states are **derived** rather than listed: each one is put through
    /// `RepoIssue.notChecked.refined(by:)`, which is the model function that
    /// decides them. A hand-written list of "what a not-checked row becomes"
    /// would be a second copy of that rule, green forever, and silent the day
    /// the rule changed underneath it — which is the trap `CaretAnchorTests`
    /// was written to escape.
    ///
    /// `observable` mirrors `RepoRegistryService.classify`'s arms, and that
    /// mirror *is* hand-made — the honest limit of this test. What it cannot go
    /// stale on is the composition, because that is being called rather than
    /// re-stated.
    @MainActor
    @Test("Every verdict a probed not-checked row can be left in has a word and a symbol")
    func aProbedNotCheckedRowAlwaysHasAWord() {
        for shown in Self.reachableFromNotChecked {
            #expect(!RepositoriesView.verdict(shown).isEmpty)
            let name = RepositoriesView.icon(shown)
            #expect(
                NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                "\(shown) names \(name), which is not an SF Symbol on this system")
        }
    }

    /// ⛔ The one that can fail. A row whose owner GitHub never answered about
    /// must not read `ok` — in any word, symbol or tint — whatever git found on
    /// its clone.
    ///
    /// This is #148's defect asserted where a reader would meet it: collapse
    /// `.notChecked + .ok` to `.ok` in the model and the page starts drawing a
    /// green tick and the word "ok" on a repository nobody could check. Every
    /// other arm is a real observation and is entitled to its own word.
    @MainActor
    @Test("No probed not-checked row ever reads ok")
    func aProbedNotCheckedRowIsNeverSpelledOk() throws {
        let appearance = try #require(NSAppearance(named: .aqua))
        let verified = try #require(Self.srgb(Palette.verified, in: appearance))

        for shown in Self.reachableFromNotChecked {
            #expect(
                RepositoriesView.verdict(shown) != RepositoriesView.verdict(.ok),
                "a repository nobody could check reads as \(RepositoriesView.verdict(.ok))")
            #expect(try #require(Self.srgb(RepositoriesView.tint(shown), in: appearance)) != verified)
        }

        // The control, and the reason the loop above is not passing merely
        // because nothing is ever green: an `.ok` row genuinely is.
        #expect(RepositoriesView.verdict(RepoIssue.ok.refined(by: .ok)) == "ok")
    }

    /// The clean clone stays `not checked` rather than becoming `ok`, said in
    /// the page's own vocabulary. Split out from the loop because it is the
    /// specific arm the issue turns on, and a failure here should name itself.
    @Test("A clean clone whose owner was never listed still reads not checked")
    func theSurvivingArmStillReadsNotChecked() {
        #expect(RepositoriesView.verdict(RepoIssue.notChecked.refined(by: .ok)) == "not checked")
    }

    /// Every verdict `RepoRegistryService.classify` can return, put through the
    /// composition. `.ok` is in the input on purpose — it is the arm where
    /// `.notChecked` survives, and leaving it out would drop the only case that
    /// distinguishes this list from `everyIssue`.
    private static let reachableFromNotChecked: [RepoIssue] = {
        let observable: [RepoIssue] = [
            .outOfScope(.otherRoot), .detached, .dirty, .unreadable("fetch failed"),
            .noRemote, .ok, .behind(by: 2), .ahead, .diverged,
        ]
        return observable.map { RepoIssue.notChecked.refined(by: $0) }
    }()

    // MARK: - The count sentence

    /// Criterion 3. With one owner unreachable the tree is only partly known, so
    /// *both* aggregate claims are claims about a whole nobody measured — the
    /// count of what needs attention, and the "nothing needs attention" that
    /// stands in for it. The sentence says what it counted and what it could not.
    @Test("With a failed listing the sentence counts nothing and says so")
    func countSentenceMakesNoClaimWhenAnOwnerFailed() {
        let sentence = RepositoriesView.countSentence(
            rows: [Self.row("phmatray/Koine", .notChecked), Self.row("phmatray/Ducky", .ok)],
            failures: [Self.failure("phmatray")], isReconciling: false, root: "/R")
        #expect(sentence.contains("2 repositories"))
        #expect(sentence.contains("1 owner could not be listed"))
        #expect(
            !sentence.contains("need"),
            "\(sentence) claims a measurement of a tree half of which was never read")
        #expect(!sentence.contains("nothing needs attention"))
    }

    /// Criterion 4, and the direct analogue of `BoardPhase.of` refusing `.empty`
    /// while `unreadableCount > 0`: "nothing is there" is a claim about the tree,
    /// and the tree was never what failed.
    @Test("With no rows and a failed listing the page does not say the tree is empty")
    func countSentenceDoesNotCallAFailedListingAnEmptyTree() {
        let sentence = RepositoriesView.countSentence(
            rows: [], failures: [Self.failure("phmatray")], isReconciling: false, root: "/R")
        #expect(!sentence.contains("Nothing found under"))
        #expect(sentence.contains("1 owner could not be listed"))
    }

    @Test("Two failed owners are counted as two")
    func countSentencePluralisesOwners() {
        let sentence = RepositoriesView.countSentence(
            rows: [], failures: [Self.failure("phmatray"), Self.failure("Atypical-Consulting")],
            isReconciling: false, root: "/R")
        #expect(sentence.contains("2 owners could not be listed"))
    }

    /// The control: with nothing failed the sentence is byte-for-byte what it was
    /// before #148. The new rules are a refusal to speak under one condition, not
    /// a rewrite of what the page says the rest of the time.
    @Test("With no failures the sentence is exactly what it always was")
    func countSentenceIsUnchangedWithoutFailures() {
        #expect(
            RepositoriesView.countSentence(
                rows: [Self.row("phmatray/Koine", .ok)], failures: [],
                isReconciling: false, root: "/R") == "1 repository · nothing needs attention")
        #expect(
            RepositoriesView.countSentence(
                rows: [], failures: [], isReconciling: false, root: "/R")
                == "Nothing found under /R.")
        #expect(
            RepositoriesView.countSentence(
                rows: [], failures: [], isReconciling: true, root: "/R")
                == "Reading GitHub, the disk and the board…")
    }

    // MARK: - The banner

    /// Criterion 1: the owner *and* the error. The line is a static so the test
    /// reads the same string the `Label` and its accessibility label render —
    /// where the banner sits on screen is still not assertable, and Task 5 of the
    /// plan is what looks at that.
    @Test("The banner names the owner and the error it got")
    func bannerNamesTheOwnerAndTheReason() {
        let line = RepositoriesView.bannerLine(
            OwnerListingFailure(owner: "phmatray", reason: "gh exited 1: HTTP 403 rate limited"))
        #expect(line.contains("phmatray"))
        #expect(line.contains("gh exited 1: HTTP 403 rate limited"))
    }

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

    // MARK: - What a row says about its board (#209)

    /// Criterion 3. `no cards` rather than `0 cards`: the criterion asks the row
    /// to *say so*, and a zero is what a reader skims past.
    @Test("A repository Elliot drives with nothing on its board says so in words")
    func emptyBoardSaysNoCards() {
        #expect(RepositoriesView.boardLine(.empty) == "no cards")
    }

    @Test("Cards are counted, and one card is not one cards")
    func cardCount() {
        #expect(RepositoriesView.boardLine(Self.tally(cards: 11)) == "11 cards")
        #expect(RepositoriesView.boardLine(Self.tally(cards: 1)) == "1 card")
    }

    @Test("Runs in flight are named only when there are some")
    func runsInFlight() {
        #expect(RepositoriesView.boardLine(Self.tally(cards: 11)) == "11 cards")
        #expect(RepositoriesView.boardLine(Self.tally(cards: 11, running: 2)) == "11 cards · 2 running")
        // A repository can be busy with no cards at all: an analysis run has no
        // card. Saying `no cards · 1 running` beats implying it is idle.
        #expect(RepositoriesView.boardLine(Self.tally(cards: 0, running: 1)) == "no cards · 1 running")
    }

    /// The convention `SyncSummary.sentence` already holds: a clean pass does
    /// not advertise a zero.
    @Test("Spend is appended only when something was spent")
    func spendIsAppendedOnlyWhenThereIsSome() {
        let free = Self.tally(cards: 3, spend: Spend(totalUSD: 0, runs: 2, unknownCost: 0))
        #expect(RepositoriesView.boardLine(free, locale: Self.enUS) == "3 cards")

        let spent = Self.tally(cards: 3, spend: Spend(totalUSD: 1.42, runs: 2, unknownCost: 0))
        #expect(RepositoriesView.boardLine(spent, locale: Self.enUS) == "3 cards · $1.42 today")
    }

    /// Criterion 2. The reason is `gh`'s own words and reaches the row verbatim
    /// — the row is not the place a machine's sentence gets paraphrased.
    @Test("The failure line quotes the reason and does not paraphrase it")
    func failureLineQuotesTheReason() {
        let reason = "gh exited 1: API rate limit exceeded"
        let line = RepositoriesView.refreshFailureLine(reason)
        #expect(line.contains(reason))
        #expect(line == "could not be refreshed: \(reason)")
    }

    // MARK: - Helpers

    private static let enUS = Locale(identifier: "en_US")

    private static func tally(
        cards: Int, running: Int = 0, spend: Spend = .nothing
    ) -> RepoBoardTally {
        RepoBoardTally(cards: cards, runsInFlight: running, spendToday: spend)
    }

    private static func row(
        _ nameWithOwner: String, _ issue: RepoIssue, fixes: [RepoFix] = []
    ) -> RepoRow {
        RepoRow(id: nameWithOwner, nameWithOwner: nameWithOwner, issue: issue, fixes: fixes)
    }

    private static func failure(_ owner: String) -> OwnerListingFailure {
        OwnerListingFailure(owner: owner, reason: "gh exited 1: could not resolve host")
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
