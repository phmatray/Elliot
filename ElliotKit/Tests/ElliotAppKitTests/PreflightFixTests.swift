import ElliotEngine
import ElliotModel
import Foundation
import TestSupport
import Testing

@testable import ElliotAppKit

/// The buttons a Preflight finding can now carry.
///
/// Until #170 this screen could only describe a remedy in prose. What is pinned
/// here is the part a view cannot assert about itself: that a check with no fix
/// offers no button — which is every check that existed before — and that
/// applying one goes back to the service rather than editing the row to look
/// fixed.
@Suite("Preflight fixes")
@MainActor
struct PreflightFixTests {

    @Test("A finding with no fix offers no button")
    func noFixNoButton() {
        // Every check that shipped before #170 constructs without `fixes`, so
        // this is the assertion that the screen did not suddenly grow buttons
        // everywhere.
        let plain = CheckResult(id: "tool.git", title: "git", status: .pass, detail: "found")
        #expect(PreflightFixes.buttons(for: plain).isEmpty)
    }

    @Test("A finding with two fixes offers both, in the order the check gave them")
    func twoFixesTwoButtons() {
        let repoID = UUID()
        let result = CheckResult(
            id: "repo.labels", title: "Labels", status: .warn, detail: "Missing: question.",
            fixes: [
                .createLabels(
                    repoID: repoID,
                    labels: [RequiredLabel(name: "question", color: "d876e3", description: "q")]
                ),
                .seedCard(
                    repoID: repoID, title: "Decide a taxonomy",
                    story: UserStory(role: "r", want: "w", benefit: "b")
                ),
            ]
        )

        let buttons = PreflightFixes.buttons(for: result)
        #expect(buttons.count == 2)
        // The deterministic one first: it is the one that resolves the finding
        // outright, and a reader scanning left to right should meet it before
        // the one that files work for later.
        #expect(buttons[0].title.contains("Create"))
        #expect(buttons[1].title == "Add a card")
        // Distinct ids, so SwiftUI can tell two buttons on one row apart.
        #expect(buttons[0].id != buttons[1].id)
    }

    @Test("A fix names the repository it belongs to, so the model can resolve it")
    func fixCarriesItsRepository() {
        // The view renders checks for several repositories from one list. A
        // button that did not carry its repository would have to be told by its
        // position on screen, which is how a fix ends up applied to the wrong
        // one.
        let repoID = UUID()
        #expect(CheckFix.createLabels(repoID: repoID, labels: []).repoID == repoID)
        #expect(
            CheckFix.seedCard(
                repoID: repoID, title: "t",
                story: UserStory(role: "r", want: "w", benefit: "b")
            ).repoID == repoID
        )
    }

    @Test("Applying a fix against an unknown repository says so rather than doing nothing")
    func unknownRepositoryIsReported() async throws {
        _ = TestHome.root
        let model = AppModel()

        // No repository with this id was ever registered. Silence here would be
        // a button that appears to work and does not — the failure mode this
        // whole screen is being taught to avoid.
        await model.apply(.createLabels(repoID: UUID(), labels: []))

        #expect(model.lastCheckFixOutcome?.succeeded == false)
        #expect(model.lastCheckFixOutcome?.detail.isEmpty == false)
    }
}
