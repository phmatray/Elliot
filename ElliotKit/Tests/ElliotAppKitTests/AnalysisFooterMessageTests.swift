import ElliotModel
import Testing

@testable import ElliotAppKit

/// The setup footer's one decision, held where `swift test` can reach it.
///
/// It was a chain of `if`s in `AnalysisPanelView.footer`, which is why the
/// third thing it has to say — a start that threw — could be written into a
/// session that did not exist and nobody noticed for two issues (#134, #136).
/// A view body is not a place a rule can be asserted.
@Suite("Analysis footer message")
struct AnalysisFooterMessageTests {

    // MARK: - The consequence, when there is nothing to refuse or report

    @Test("No lens armed is itself a refusal — the button spends nothing")
    func noLenses() {
        let message = AnalysisFooterMessage.setup(angleCount: 0, failure: nil, refusal: nil)
        #expect(message.text == "Pick at least one lens.")
        #expect(message.tone == .refused)
        #expect(message.symbol == "bolt.fill")
    }

    @Test("One lens is singular, and it is armed")
    func oneLens() {
        let message = AnalysisFooterMessage.setup(angleCount: 1, failure: nil, refusal: nil)
        #expect(message.text == "Reads the repository once.")
        #expect(message.tone == .armed)
        #expect(message.symbol == "bolt.fill")
    }

    @Test("Several lenses name the count, because that is what Start is spending")
    func severalLenses() {
        let message = AnalysisFooterMessage.setup(angleCount: 3, failure: nil, refusal: nil)
        #expect(message.text == "Reads the repository 3 times — one run per lens.")
        #expect(message.tone == .armed)
        #expect(message.symbol == "bolt.fill")
    }

    // MARK: - Precedence

    @Test("A failure outranks an armed consequence")
    func failureOutranksTheConsequence() {
        // The whole of #138 in one expectation. Toggling a lens changes what the
        // *next* start would spend; it does not un-fail the last one, so the
        // slot must not go back to advertising a cost after refusing to pay one.
        let message = AnalysisFooterMessage.setup(angleCount: 3, failure: "boom", refusal: nil)
        #expect(message.text == "boom")
        #expect(message.tone == .refused)
        // Distinct from the consequence's bolt: this is not what the button is
        // about to do, it is what it did not do.
        #expect(message.symbol == "exclamationmark.triangle.fill")
    }

    @Test("A refusal outranks a failure, because Start cannot be pressed at all")
    func refusalOutranksTheFailure() {
        // Not a preference between two messages: with a refusal standing, Start
        // is `.disabled`, so the failure is about an attempt that can no longer
        // be repeated. The refusal is the one that names something to go and do.
        let message = AnalysisFooterMessage.setup(
            angleCount: 3, failure: "boom", refusal: "A Preflight check is failing.")
        #expect(message.text == "A Preflight check is failing.")
        #expect(message.tone == .refused)
        #expect(message.symbol == "exclamationmark.octagon.fill")
    }

    @Test("A refusal outranks the consequence too, armed or not")
    func refusalOutranksTheConsequence() {
        for angles in [0, 1, 8] {
            let message = AnalysisFooterMessage.setup(
                angleCount: angles, failure: nil, refusal: "Pick a single repository to analyse.")
            #expect(message.text == "Pick a single repository to analyse.")
            #expect(message.tone == .refused)
        }
    }

    // MARK: - A lens that is already reading

    @Test("One busy lens is named, in the singular, and says the start is all or nothing")
    func oneClashingLens() {
        let message = AnalysisFooterMessage.setup(
            angleCount: 3, clashing: [.techDebt], failure: nil, refusal: nil)
        #expect(
            message.text == "Tech debt was still reading when the lenses were last checked — "
                + "Start is all or nothing, so untick it or wait.")
        #expect(message.tone == .refused)
        #expect(message.symbol == "hourglass")
    }

    @Test("Several busy lenses are listed, and the sentence agrees with itself")
    func severalClashingLenses() {
        let message = AnalysisFooterMessage.setup(
            angleCount: 4, clashing: [.bugs, .tests, .techDebt], failure: nil, refusal: nil)
        #expect(
            message.text == "Bugs, Tests and Tech debt were still reading when the lenses were "
                + "last checked — Start is all or nothing, so untick them or wait.")
        #expect(message.tone == .refused)
    }

    /// ⛔ The whole of #293's footer half. `AnalysisService.start` throws on the
    /// first clash *before* it saves anything, so a count of the startable
    /// lenses would be a figure for something that cannot happen: seven runs
    /// that will not start.
    @Test("A clash replaces the spend, it does not reduce it")
    func aClashNeverPrintsAReducedCount() {
        let message = AnalysisFooterMessage.setup(
            angleCount: 8, clashing: [.bugs], failure: nil, refusal: nil)
        #expect(!message.text.contains("Reads the repository"))
        #expect(!message.text.contains("7"))
    }

    /// The order is the caller's, because the caller is the one that armed them
    /// — the strip's order, the same list Start hands the service.
    @Test("The lenses are named in the order they were given")
    func theSentenceKeepsTheCallersOrder() {
        let message = AnalysisFooterMessage.setup(
            angleCount: 2, clashing: [.uxAndUI, .bugs], failure: nil, refusal: nil)
        #expect(message.text.hasPrefix("UX & UI and Bugs "))
    }

    @Test("No clash leaves the consequence exactly as it was")
    func noClashChangesNothing() {
        let message = AnalysisFooterMessage.setup(
            angleCount: 3, clashing: [], failure: nil, refusal: nil)
        #expect(message.text == "Reads the repository 3 times — one run per lens.")
        #expect(message.tone == .armed)
    }

    @Test("A failure outranks a clash, and a refusal outranks both")
    func clashSitsBelowTheFailureAndTheRefusal() {
        // Same argument as the failure-over-consequence rule: unticking a lens
        // changes what the *next* press would do and does not un-fail the last
        // one. The clash is a sentence about the next press, so it ranks with
        // the consequence rather than above the failure.
        let overFailure = AnalysisFooterMessage.setup(
            angleCount: 3, clashing: [.bugs], failure: "boom", refusal: nil)
        #expect(overFailure.text == "boom")

        let overRefusal = AnalysisFooterMessage.setup(
            angleCount: 3, clashing: [.bugs], failure: "boom",
            refusal: "A Preflight check is failing.")
        #expect(overRefusal.text == "A Preflight check is failing.")
    }

    /// ⚠️ The snapshot hedge. The panel reads which lenses are busy and a run
    /// can start or finish in the gap before the press, so the sentence reports
    /// a reading rather than claiming a present fact — the board's own "`gh` is
    /// the fact, the prose is a hint" rule, one layer in.
    @Test("The sentence reports a reading, it does not claim the present")
    func theWordingIsHonestAboutBeingASnapshot() {
        let message = AnalysisFooterMessage.setup(
            angleCount: 1, clashing: [.bugs], failure: nil, refusal: nil)
        #expect(message.text.contains("when the lenses were last checked"))
        #expect(!message.text.contains("is already running"))
    }

    // MARK: - The accents it is allowed to ask for

    @Test("Every case it can produce asks for one of two accents, never a sixth")
    func onlyTwoTones() {
        // `BrandColorTests` pins the five consequence accents. `Tone` having
        // exactly two cases is what stops this value being the place a sixth
        // arrives by accident — it cannot name one.
        let every = [
            AnalysisFooterMessage.setup(angleCount: 0, failure: nil, refusal: nil),
            AnalysisFooterMessage.setup(angleCount: 1, failure: nil, refusal: nil),
            AnalysisFooterMessage.setup(angleCount: 9, failure: nil, refusal: nil),
            AnalysisFooterMessage.setup(angleCount: 2, failure: "boom", refusal: nil),
            AnalysisFooterMessage.setup(angleCount: 2, failure: nil, refusal: "no"),
            AnalysisFooterMessage.setup(
                angleCount: 2, clashing: [.bugs], failure: nil, refusal: nil),
            AnalysisFooterMessage.setup(
                angleCount: 8, clashing: AnalysisAngle.allCases, failure: nil, refusal: nil),
        ]
        #expect(every.allSatisfy { $0.tone == .armed || $0.tone == .refused })
        // And none of them is ever blank: an empty slot is what the reader read
        // as "nothing happened" in the first place.
        #expect(every.allSatisfy { !$0.text.isEmpty && !$0.symbol.isEmpty })
    }
}
