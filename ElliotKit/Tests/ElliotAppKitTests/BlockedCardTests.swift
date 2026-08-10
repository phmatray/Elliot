import ElliotEngine
import ElliotModel
import Foundation
import TestSupport
import Testing

@testable import ElliotAppKit

/// The badge a card draws when its repository will not let it move (#298).
///
/// Until now it was one fixed sentence for seven different failures, with no
/// route to any of them — and it was drawn from the *in-memory* sweep results
/// while the drop was refused by the *persisted* verdict, so the two disagreed
/// for the whole of every launch.
@Suite("Blocked card badge")
@MainActor
struct BlockedCardTests {

    private func repo(_ name: String, preflight: PreflightState? = nil) -> Repo {
        Repo(
            path: "/tmp/\(name)", nameWithOwner: "o/\(name)", displayName: name,
            preflight: preflight
        )
    }

    private func check(_ id: String, _ title: String, _ status: CheckStatus) -> CheckResult {
        CheckResult(id: id, title: title, status: status, detail: "d")
    }

    @Test("A repository that passed, and one nobody has read, draw nothing")
    func nothingToSay() {
        let passing = repo("passing", preflight: .passing)
        let unread = repo("unread")
        let model = AppModel()
        model.testOnlySeed(repos: [passing, unread], cards: [])

        #expect(model.blockedBadge(for: passing) == nil)
        // ⚠️ The deliberate half of #302: every repository is unmeasured for the
        // first seconds of every launch, and a badge shouting about it on every
        // card would be worse than the silence it replaces. `notChecked` permits
        // a move, so nothing on the card may claim otherwise.
        #expect(model.blockedBadge(for: unread) == nil)
    }

    @Test("A failing repository names the check that failed")
    func namesTheCheck() {
        let blocked = repo("blocked", preflight: .failing)
        let model = AppModel()
        model.testOnlySeed(repos: [blocked], cards: [])
        model.testOnlySeedChecks(repo: blocked.id, [
            check("repo.exists", "Git repository", .pass),
            check("repo.isMainCheckout", "Main checkout", .fail),
            check("repo.labels", "Labels", .warn),
        ])

        let badge = model.blockedBadge(for: blocked)
        #expect(badge?.sentence == "Blocked: Main checkout")
        #expect(badge?.address == CheckAddress(repoID: blocked.id, checkID: "repo.isMainCheckout"))
        #expect(badge?.openHint == "Show Main checkout in Preflight")
    }

    /// The launch window, which is the case that shipped drawing nothing.
    ///
    /// `Repo.preflight` survives a quit and the readings do not, so between
    /// launch and the first sweep landing a repository refused last session
    /// refuses every drag with nothing in memory to name the reason. Saying
    /// *that* the card cannot move beats a card that looks movable and is not.
    @Test("A verdict with no reading behind it still says the card cannot move")
    func aVerdictWithoutAReadingStillDraws() {
        let blocked = repo("blocked", preflight: .failing)
        let model = AppModel()
        model.testOnlySeed(repos: [blocked], cards: [])

        let badge = model.blockedBadge(for: blocked)
        #expect(badge != nil)
        #expect(badge?.sentence == "Repository blocked — see Preflight")
        // Nothing to expand, so the press only takes the reader to the section.
        #expect(badge?.address == nil)
        #expect(badge?.openHint == "Show this repository in Preflight")
    }

    /// The other direction of the same rule, and the reason it is not "draw a
    /// badge whenever a reading holds a failure".
    ///
    /// The badge answers the question the *drop* answers, and the drop reads
    /// `Repo.preflightVerdict`. A card claiming to be stuck while `evaluateMove`
    /// would let it move is a second opinion — the thing `preview` refuses to be
    /// one screen over.
    @Test("A reading that failed does not draw a badge the verdict does not support")
    func theVerdictDecides() {
        let allowed = repo("allowed", preflight: .passing)
        let model = AppModel()
        model.testOnlySeed(repos: [allowed], cards: [])
        model.testOnlySeedChecks(repo: allowed.id, [check("x", "Main checkout", .fail)])

        #expect(model.blockedBadge(for: allowed) == nil)
    }

    // MARK: - Pressing it

    @Test("Pressing the badge unfolds Preflight, aims it, and opens the check")
    func pressingOpensTheCheck() throws {
        let blocked = repo("blocked", preflight: .failing)
        let model = AppModel()
        model.testOnlySeed(repos: [blocked], cards: [])
        model.testOnlySeedChecks(repo: blocked.id, [check("repo.profile", "Repo profile", .fail)])

        let badge = try #require(model.blockedBadge(for: blocked))
        model.openPreflight(badge)

        #expect(model.console.face == .preflight)
        #expect(model.preflightFocus == blocked.id)
        // `failing: false` is the point: the disclosure is open because the
        // reader was sent here, not because the default happens to agree.
        #expect(
            model.isCheckExpanded(
                CheckAddress(repoID: blocked.id, checkID: "repo.profile"), failing: false))
    }

    /// The defect `CheckAddress` exists for, and it is invisible with one
    /// repository registered.
    ///
    /// Every repository produces `repo.profile`, `repo.labels`, `repo.clean` …
    /// so a disclosure map keyed on the check alone opens the same row on all of
    /// them at once — and a badge aimed at one repository would open a finding
    /// on every other.
    @Test("Opening one repository's check leaves the same check on another shut")
    func expansionIsPerRepository() throws {
        let first = repo("first", preflight: .failing)
        let second = repo("second", preflight: .failing)
        let model = AppModel()
        model.testOnlySeed(repos: [first, second], cards: [])
        model.testOnlySeedChecks(repo: first.id, [check("repo.profile", "Repo profile", .fail)])
        model.testOnlySeedChecks(repo: second.id, [check("repo.profile", "Repo profile", .pass)])

        model.openPreflight(try #require(model.blockedBadge(for: first)))

        #expect(
            model.isCheckExpanded(
                CheckAddress(repoID: first.id, checkID: "repo.profile"), failing: false))
        #expect(
            !model.isCheckExpanded(
                CheckAddress(repoID: second.id, checkID: "repo.profile"), failing: false))
        // And the machine-wide family cannot collide with either: it is keyed on
        // no repository at all.
        #expect(!model.isCheckExpanded(CheckAddress(repoID: nil, checkID: "repo.profile"), failing: false))
    }

    /// ⚠️ **The half of #298 that no behavioural test can reach.**
    ///
    /// Everything above is about `AppModel`, and `CardView` could stop calling
    /// any of it — draw the old fixed sentence again, or draw the badge with no
    /// way to press it — with every other test here still green. That is the
    /// `CaretAnchorTests` finding restated: the arithmetic was pure, extracted
    /// and tested, and the decoration still never appeared, because nothing
    /// pinned the step between the two.
    ///
    /// So the claim is about the source, and it is checked in the source.
    @Test("The card draws the badge's own sentence, and pressing it opens Preflight")
    func theCardRendersWhatTheModelDecided() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ElliotAppKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ElliotKit
            .appendingPathComponent("Sources/ElliotAppKit/CardView.swift")
        // Comments are stripped first, for the reason every gate in this
        // repository strips them: the prose beside these lines discusses exactly
        // what is being looked for.
        let code = try String(contentsOf: file, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        #expect(
            code.contains("badge.sentence"),
            """
            CardView no longer draws the sentence `BlockedBadge` decided — the card is back \
            to one fixed line for seven different failures.
            """
        )
        // ⚠️ **Counted, not merely present, and that is not fussiness — the
        // first draft of this gate asserted presence and a break-test walked
        // straight through it.** Deleting the badge's `Button` entirely, leaving
        // a plain `Label`, left the `.accessibilityActions` twin behind: one
        // call site still matched, the whole suite stayed green, and the card
        // had silently gone back to naming a check with no way to reach it.
        //
        // Two, because the card is `.accessibilityElement(children: .combine)`:
        // a button nested inside a combined element is readable and not
        // pressable, so the same act has to be offered twice or it is offered to
        // half the readers. A third would be a second control for one act.
        let opens = code.components(separatedBy: "model.openPreflight(badge)").count - 1
        #expect(
            opens == 2,
            """
            CardView reaches `openPreflight` \(opens) times; it needs exactly two — the \
            badge's own Button, and its `.accessibilityActions` twin. At one, either the \
            badge names the failing check with no way to reach it, or it is reachable by \
            pointer only.
            """
        )
    }

    @Test("A failing check opens on arrival, and the reader's collapse wins after that")
    func theReadersCollapseWins() {
        let model = AppModel()
        let address = CheckAddress(repoID: UUID(), checkID: "tool.gh")

        #expect(model.isCheckExpanded(address, failing: true))
        #expect(!model.isCheckExpanded(address, failing: false))

        model.setCheckExpanded(address, false)
        #expect(!model.isCheckExpanded(address, failing: true))
    }
}
