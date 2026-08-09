import Foundation
import Testing

@testable import ElliotModel

private let midnight = Date(timeIntervalSince1970: 1_770_000_000)

/// #308: `spendByKind` was written, documented and tested, and called by nothing
/// outside tests. The analysis panel starts up to eight runs from one button and
/// no screen said what that costs against filing one issue.
///
/// What is asserted here is the pairing — that a column carries the runs its
/// figure cannot have counted — and the boundary, which is the field that makes
/// the split and the total comparable at all.
@Suite("The day's spend, split by skill")
struct DaySpendTests {

    private func day(
        total: Spend = .nothing, byKind: [SkillKind: Spend] = [:]
    ) -> DaySpend {
        DaySpend(since: midnight, total: total, byKind: byKind)
    }

    // MARK: - What a missing kind means

    /// The query groups over runs that **ended** in the period, so a kind absent
    /// from it had none. Zero runs, nothing unknown, nothing spent — which is a
    /// fact, not a gap.
    @Test("A kind nobody ran today is nothing, not a hole")
    func anAbsentKindIsNothing() {
        #expect(day().spend(.mergePR) == .nothing)
        #expect(day().spend(.mergePR).isComplete)
    }

    // MARK: - The columns

    @Test("Every skill gets a column, in one order, however quiet the day was")
    func everyKindGetsAColumn() {
        let figures = day().figures(inFlight: [:])
        #expect(figures.map(\.kind) == SkillKind.allCases)
        #expect(figures.allSatisfy { $0.figure.amount(locale: Locale(identifier: "en_US")) == "$0.00" })
    }

    @Test("A column is the spend of its own kind and of no other")
    func aColumnIsItsOwnKind() {
        let figures = day(byKind: [
            .createIssue: Spend(totalUSD: 0.5, runs: 1, unknownCost: 0),
            .analyzeRepo: Spend(totalUSD: 10, runs: 8, unknownCost: 0),
        ]).figures(inFlight: [:])

        let byKind = Dictionary(uniqueKeysWithValues: figures.map { ($0.kind, $0.figure) })
        #expect(byKind[.createIssue]?.spend.totalUSD == 0.5)
        #expect(byKind[.analyzeRepo]?.spend.totalUSD == 10)
        #expect(byKind[.analyzeRepo]?.spend.runs == 8)
        #expect(byKind[.mergePR]?.spend == .nothing)
    }

    // MARK: - A column that under-reports has to say so

    /// ⛔ The reason this is a `SpendFigure` and not a bare `Spend`.
    /// `spend(since:)` keys on `endedAt`, so eight lenses in flight contribute
    /// **nothing**: the analyze-repo column reads `$0.00`, and `Spend.isComplete`
    /// — which only knows about finished runs whose cost went unrecorded — says
    /// it is the whole bill. That is exactly the hour a reader is watching it.
    @Test("A skill whose runs are all still going says so instead of reading free")
    func runsInFlightAreNamed() {
        let figures = day().figures(inFlight: [.analyzeRepo: 8])
        let analyze = figures.first { $0.kind == .analyzeRepo }!.figure

        #expect(analyze.spend == .nothing)
        #expect(analyze.spend.isComplete, "the narrower question is the one that lies here")
        #expect(!analyze.isComplete)
        #expect(analyze.sentence(locale: Locale(identifier: "en_US"))
            == "$0.00 — at least; 8 runs in flight are not in this figure yet")
    }

    @Test("A skill with a run that never reported a cost is a floor, not a bill")
    func unknownCostsAreNamed() {
        let figures = day(byKind: [
            .mergePR: Spend(totalUSD: 2, runs: 3, unknownCost: 1)
        ]).figures(inFlight: [:])
        let merge = figures.first { $0.kind == .mergePR }!.figure

        #expect(!merge.isComplete)
        #expect(merge.sentence(locale: Locale(identifier: "en_US"))
            == "$2.00 — at least; 1 of 3 runs never reported a cost")
    }

    @Test("A quiet skill claims nothing it cannot stand behind")
    func aQuietColumnIsComplete() {
        let figures = day(byKind: [.createIssue: Spend(totalUSD: 1, runs: 2, unknownCost: 0)])
            .figures(inFlight: [:])
        #expect(figures.first { $0.kind == .createIssue }!.figure.isComplete)
    }

    /// In flight is counted per kind, not spread over all of them: a merge
    /// running says nothing about what an analysis figure is missing.
    @Test("One kind's runs in flight belong to that kind's column")
    func inFlightIsPerKind() {
        let figures = day().figures(inFlight: [.mergePR: 2])
        #expect(figures.first { $0.kind == .mergePR }!.figure.inFlight == 2)
        #expect(figures.first { $0.kind == .analyzeRepo }!.figure.inFlight == 0)
    }

    // MARK: - The boundary

    /// The field that makes the pair a *reading* rather than two numbers. Two
    /// `startOfDay(for: Date())` calls, one per query, are two different days
    /// for whichever refresh straddles midnight.
    @Test("The reading carries the instant both halves were measured from")
    func theBoundaryTravelsWithTheReading() {
        #expect(day(total: Spend(totalUSD: 3, runs: 1, unknownCost: 0)).since == midnight)
        // Nothing read yet is not this morning.
        #expect(DaySpend.nothing.since == .distantPast)
        #expect(DaySpend.nothing.total == .nothing)
        #expect(DaySpend.nothing.byKind.isEmpty)
    }

    // MARK: - The mark a column can afford

    /// A row of four `sentence()`s wrapped to three amber lines each and was
    /// taller than every band above it — measured by rendering it. The `+` is the
    /// mark that survives in a column; the sentence moves to `help` and to the
    /// spoken label, and the caller is told so.
    @Test("A floor is marked, so a column never reads as a settled bill")
    func aFloorIsMarkedInAColumn() {
        let us = Locale(identifier: "en_US")
        let inFlight = SpendFigure(spend: Spend(totalUSD: 3.15, runs: 2, unknownCost: 0), inFlight: 2)
        let unknown = SpendFigure(spend: Spend(totalUSD: 2, runs: 3, unknownCost: 1), inFlight: 0)
        let settled = SpendFigure(spend: Spend(totalUSD: 1, runs: 1, unknownCost: 0), inFlight: 0)

        #expect(inFlight.amountMark(locale: us) == "$3.15+")
        #expect(unknown.amountMark(locale: us) == "$2.00+")
        // No mark where there is nothing to qualify — a `+` on every figure is a
        // `+` that means nothing.
        #expect(settled.amountMark(locale: us) == "$1.00")
        #expect(settled.amountMark(locale: us) == settled.amount(locale: us))
    }

    // MARK: - How many runs a figure is over

    @Test("The run count is worded once, here")
    func runsAreWordedOnce() {
        #expect(Spend.nothing.runsSentence == "no runs")
        #expect(Spend(totalUSD: 1, runs: 1, unknownCost: 0).runsSentence == "1 run")
        #expect(Spend(totalUSD: 1, runs: 8, unknownCost: 3).runsSentence == "8 runs")
    }
}
