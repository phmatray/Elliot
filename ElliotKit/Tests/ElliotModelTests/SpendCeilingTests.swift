import Foundation
import Testing

@testable import ElliotModel

@Suite("Spend ceiling")
struct SpendCeilingTests {

    @Test("Off by default, because a ceiling nobody chose looks like a bug")
    func offIsOff() {
        #expect(SpendCeiling.off.perRunUSD == nil)
        #expect(SpendCeiling.off.perDayUSD == nil)
        #expect(SpendCeiling.off.daylimitReached(spentToday: 1_000_000) == false)
    }

    @Test("Zero and negative mean no ceiling, not a ceiling of nothing")
    func zeroIsOff() {
        // A ceiling of zero would refuse every run forever, which reads as the
        // app being broken rather than as a setting.
        let ceiling = SpendCeiling(perRunUSD: 0, perDayUSD: -5)
        #expect(ceiling.perRunUSD == nil)
        #expect(ceiling.perDayUSD == nil)
    }

    @Test("A non-finite ceiling is no ceiling")
    func nonFiniteIsOff() {
        #expect(SpendCeiling(perRunUSD: .nan, perDayUSD: .infinity).perRunUSD == nil)
        #expect(SpendCeiling(perRunUSD: .nan, perDayUSD: .infinity).perDayUSD == nil)
    }

    @Test("The daily limit is reached AT the ceiling, not past it")
    func atTheCeilingCounts() {
        let ceiling = SpendCeiling(perRunUSD: nil, perDayUSD: 10)
        #expect(ceiling.daylimitReached(spentToday: 9.99) == false)
        // At the ceiling the budget is spent; admitting one more run would put
        // the day over it by whatever that run costs.
        #expect(ceiling.daylimitReached(spentToday: 10) == true)
        #expect(ceiling.daylimitReached(spentToday: 10.01) == true)
    }

    @Test("Decoding sanitises, because the store is a file anyone can edit")
    func decodingSanitises() throws {
        // The same trap `SchedulerLimits` fell into: the synthesised
        // `init(from:)` assigns directly and skips the check.
        let data = Data(#"{"perRunUSD":0,"perDayUSD":-3}"#.utf8)
        let decoded = try JSONDecoder().decode(SpendCeiling.self, from: data)
        #expect(decoded == .off)
    }

    @Test("A ceiling survives a round trip")
    func roundTrip() throws {
        let original = SpendCeiling(perRunUSD: 2.5, perDayUSD: 40)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(SpendCeiling.self, from: data) == original)
    }

    @Test("An absent key decodes to no ceiling rather than failing")
    func absentKeysDecode() throws {
        // `off` encodes both fields as null; an older build's row may not carry
        // the keys at all, and refusing to decode it would take the settings
        // read down with it.
        let decoded = try JSONDecoder().decode(SpendCeiling.self, from: Data("{}".utf8))
        #expect(decoded == .off)
    }
}

@Suite("Spend")
struct SpendTests {

    @Test("A complete total says the amount and nothing else")
    func completeIsJustTheAmount() {
        let spend = Spend(totalUSD: 33.9643, runs: 6, unknownCost: 0)
        #expect(spend.isComplete)
        #expect(spend.sentence(locale: Locale(identifier: "en_US")) == "$33.96")
    }

    @Test("A partial total never claims to be the total")
    func partialSaysAtLeast() {
        // A run whose cost was never recorded must not read the same as a run
        // that cost nothing. Saying "$12.00" for a set with unknowns understates
        // a bill and gives no way to tell.
        let spend = Spend(totalUSD: 12, runs: 5, unknownCost: 2)
        #expect(!spend.isComplete)
        let sentence = spend.sentence(locale: Locale(identifier: "en_US"))
        #expect(sentence.contains("at least"))
        #expect(sentence.contains("2 of 5"))
    }

    @Test("Nothing spent is complete, not unknown")
    func nothingIsComplete() {
        #expect(Spend.nothing.isComplete)
        #expect(Spend.nothing.sentence(locale: Locale(identifier: "en_US")) == "$0.00")
    }
}
