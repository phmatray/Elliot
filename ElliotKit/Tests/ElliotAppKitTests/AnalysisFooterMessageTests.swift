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
        ]
        #expect(every.allSatisfy { $0.tone == .armed || $0.tone == .refused })
        // And none of them is ever blank: an empty slot is what the reader read
        // as "nothing happened" in the first place.
        #expect(every.allSatisfy { !$0.text.isEmpty && !$0.symbol.isEmpty })
    }
}
