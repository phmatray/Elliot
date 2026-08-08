import Foundation
import Testing

@testable import ElliotModel

/// What the forget confirmation says, decided here rather than in either of the
/// two screens that show it. The two tooltips had already drifted — one named
/// cards, the other named nothing — which is why the wording is a value.
@Suite("Forget impact")
struct ForgetImpactTests {

    @Test("All four counts are named, even the zeroes")
    func namesEveryKind() {
        let impact = ForgetImpact(cards: 3, runs: 12, analyses: 1, proposals: 0)
        // Zeroes are stated rather than dropped: a reader who cannot tell
        // "none" from "not counted" has no basis to hesitate, which is the
        // whole point of showing counts instead of prose.
        #expect(impact.countsSentence == "3 cards, 12 runs, 1 analysis and 0 proposals")
    }

    @Test("Singulars are singular, and `analysis` is not `analysiss`")
    func plurals() {
        let one = ForgetImpact(cards: 1, runs: 1, analyses: 1, proposals: 1)
        #expect(one.countsSentence == "1 card, 1 run, 1 analysis and 1 proposal")
        let many = ForgetImpact(cards: 2, runs: 2, analyses: 2, proposals: 2)
        #expect(many.countsSentence == "2 cards, 2 runs, 2 analyses and 2 proposals")
    }

    @Test("An untouched repository is empty")
    func emptiness() {
        #expect(ForgetImpact().isEmpty)
        #expect(!ForgetImpact(proposals: 1).isEmpty)
    }

    @Test("The message names the counts, the path, and that it cannot be undone")
    func message() {
        let prompt = ForgetPrompt(
            impact: ForgetImpact(cards: 3, runs: 12, analyses: 1, proposals: 0),
            displayName: "Elliot",
            path: "/tmp/Elliot")
        #expect(prompt.title == "Forget Elliot?")
        #expect(prompt.message == """
            This deletes 3 cards, 12 runs, 1 analysis and 0 proposals, and everything Elliot \
            recorded about it. It cannot be undone. The clone at /tmp/Elliot is left exactly \
            as it is.
            """)
    }

    @Test("A repository with nothing to lose still says so, and still says the clone is safe")
    func emptyMessage() {
        let prompt = ForgetPrompt(impact: ForgetImpact(), displayName: "Koine", path: "/tmp/Koine")
        #expect(prompt.message == """
            Elliot holds no cards, runs, analyses or proposals for it, so there is nothing to \
            lose. The clone at /tmp/Koine is left exactly as it is.
            """)
    }

    @Test("The tooltip names the board consequence, not only the checkout")
    func tooltip() {
        // Criterion 4. The text Preflight shipped named *only* the checkout —
        // the one thing that does not happen.
        let text = ForgetPrompt.tooltip(displayName: "Elliot")
        #expect(text == "Forget Elliot — its cards, runs, analyses and proposals go with it. "
            + "The clone on disk is untouched.")
        for kind in ["cards", "runs", "analyses", "proposals"] {
            #expect(text.contains(kind))
        }
    }

    @Test("Both screens confirm with the same verb")
    func oneVerb() {
        // Preflight said "Remove", Repositories said "Forget", for one act.
        #expect(ForgetPrompt.confirmLabel == "Forget")
    }
}
