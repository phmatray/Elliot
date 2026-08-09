import Foundation
import Testing

@testable import ElliotModel

/// A spend figure says what it cannot yet include.
///
/// `BoardStore.spend(since:)` keys on `endedAt`, so a run still going
/// contributes nothing to the day. The screen could only ask `Spend.isComplete`,
/// which counts *finished* runs whose cost went unrecorded — so during an
/// eight-lens analysis the day read near zero, in silence, and the whole wave
/// landed on the total after the money was spent.
@Suite("Spend figure")
struct SpendFigureTests {

    private static let quiet = Spend(totalUSD: 4.5, runs: 3, unknownCost: 0)
    private static let withUnknowns = Spend(totalUSD: 4.5, runs: 3, unknownCost: 1)

    @Test("With nothing running, the figure is the spend")
    func noRunsInFlightChangesNothing() {
        let figure = SpendFigure(spend: Self.quiet, inFlight: 0)
        #expect(figure.isComplete)
        #expect(figure.sentence() == Self.quiet.sentence())
    }

    /// The case the screen got wrong: every run finished and reported its cost,
    /// so `Spend.isComplete` is `true` — and three more are spending right now.
    @Test("A complete Spend is not a complete figure while runs are in flight")
    func inFlightMakesTheFigureIncomplete() {
        let figure = SpendFigure(spend: Self.quiet, inFlight: 3)
        #expect(Self.quiet.isComplete)
        #expect(figure.isComplete == false)
        #expect(figure.sentence().contains("3 runs in flight"))
    }

    @Test("The figure is a floor, and says so")
    func inFlightSaysAtLeast() {
        #expect(SpendFigure(spend: Self.quiet, inFlight: 1).sentence().contains("at least"))
    }

    @Test("One run in flight is not spoken of in the plural")
    func singularReadsAsEnglish() {
        let sentence = SpendFigure(spend: Self.quiet, inFlight: 1).sentence()
        #expect(sentence.contains("1 run in flight is not"))
        #expect(sentence.contains("runs in flight") == false)
    }

    /// Both reasons a total can be a floor, in one sentence rather than two
    /// competing ones.
    @Test("Unrecorded costs and runs in flight are both named")
    func bothCaveatsSurvive() {
        let sentence = SpendFigure(spend: Self.withUnknowns, inFlight: 2).sentence()
        #expect(sentence.contains("1 of 3 runs never reported a cost"))
        #expect(sentence.contains("2 runs in flight"))
        #expect(sentence.hasPrefix(SpendFigure(spend: Self.withUnknowns, inFlight: 0).amount()))
    }

    @Test("Unrecorded costs alone still read exactly as they did")
    func unknownsAloneAreUnchanged() {
        let figure = SpendFigure(spend: Self.withUnknowns, inFlight: 0)
        #expect(figure.isComplete == false)
        #expect(figure.sentence() == Self.withUnknowns.sentence())
    }

    /// ⛔ A count is a fact; a projected cost is the invention `unknownCost`
    /// exists to prevent. The figure must never grow because something started.
    @Test("A run in flight changes the caveat, never the number")
    func inFlightNeverMovesTheTotal() {
        let idle = SpendFigure(spend: Self.quiet, inFlight: 0)
        let busy = SpendFigure(spend: Self.quiet, inFlight: 4)
        #expect(idle.amount() == busy.amount())
        #expect(busy.spend.totalUSD == Self.quiet.totalUSD)
    }

    @Test("Nothing spent and nothing running is complete, not unknown")
    func nothingIsComplete() {
        #expect(SpendFigure(spend: .nothing, inFlight: 0).isComplete)
    }
}
