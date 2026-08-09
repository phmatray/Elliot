import Foundation
import Testing

@testable import ElliotModel

@Suite("Value weights")
struct ValueWeightsTests {

    /// The weights are data, in the shape of `AnalysisAngle.briefing`: adding a
    /// lens stays a case and a number, and nothing else in the package branches
    /// on which lens a card came through. A lens with no weight would compile
    /// only if somebody wrote a `default`, which is the thing this shape exists
    /// to make impossible.
    @Test("Every lens carries a weight, and the range is real", arguments: AnalysisAngle.allCases)
    func everyAngleIsWeighted(angle: AnalysisAngle) {
        #expect(angle.valueWeight > 0)
        #expect(angle.valueWeight <= 1)
    }

    @Test("The lenses are not all worth the same, or the weight says nothing")
    func anglesAreDistinguished() {
        let weights = AnalysisAngle.allCases.map(\.valueWeight)
        #expect(Set(weights).count > 1)
    }

    /// A card written by hand carries no lens, and burying it under every
    /// machine-found card is the failure `CardValue.neverAppraised` exists to
    /// prevent, arriving one field over. So the unlensed weight sits strictly
    /// inside the range rather than at the bottom of it.
    @Test("A card that came through no lens is neither promoted nor buried")
    func unlensedSitsInsideTheRange() throws {
        let weights = AnalysisAngle.allCases.map(\.valueWeight)
        let lowest = try #require(weights.min())
        let highest = try #require(weights.max())
        #expect(AnalysisAngle.unlensedWeight > lowest)
        #expect(AnalysisAngle.unlensedWeight < highest)
        #expect(!AnalysisAngle.unlensedCode.isEmpty)
    }

    /// Cheaper is worth more, and that ordering is the only thing the numbers
    /// themselves have to guarantee.
    @Test("A smaller effort outranks a larger one")
    func effortIsOrdered() {
        #expect(Effort.small.valueWeight > Effort.medium.valueWeight)
        #expect(Effort.medium.valueWeight > Effort.large.valueWeight)
        // Unreachable from `CardValue.of` — an unstated effort is refused, not
        // scored — and zero so that a future caller that scores it anyway gets
        // an obviously wrong answer rather than a plausible one.
        #expect(Effort.unstated.valueWeight == 0)
    }

    @Test("A grounded citation outranks a missing one, and an absent one scores nothing")
    func groundingIsOrdered() {
        #expect(Grounding.grounded.valueWeight > Grounding.missing(count: 1).valueWeight)
        #expect(Grounding.missing(count: 1).valueWeight > 0)
        #expect(Grounding.notCited.valueWeight == 0)
    }
}
