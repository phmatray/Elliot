import Foundation

/// What a set of runs cost, and how much of that answer is actually known.
///
/// `unknownCost` is the load-bearing field. A run whose `totalCostUSD` was never
/// recorded — it crashed, it was cancelled before the result event, the app died
/// — must not read the same as a run that cost nothing. Collapsing the two is
/// exactly the bug `workingTreeChanged` avoids by distinguishing checked-and-
/// clean from never-checked, and here it would quietly understate a bill.
public struct Spend: Sendable, Equatable {
    public var totalUSD: Double
    /// Every run in the period, whether or not its cost is known.
    public var runs: Int
    /// How many of those contributed nothing to `totalUSD` because nobody knows
    /// what they cost.
    public var unknownCost: Int

    public static let nothing = Spend(totalUSD: 0, runs: 0, unknownCost: 0)

    public init(totalUSD: Double, runs: Int, unknownCost: Int) {
        self.totalUSD = totalUSD
        self.runs = runs
        self.unknownCost = unknownCost
    }

    /// True when the total accounts for every run in the period.
    public var isComplete: Bool { unknownCost == 0 }

    /// One sentence, so the caller does not invent a second wording.
    ///
    /// Never claims a total it cannot stand behind: with unknowns it says "at
    /// least", because that is what a sum over a partial set is.
    public func sentence(locale: Locale = .current) -> String {
        let amount = MoneyFormat.usd(totalUSD, locale: locale)
        guard unknownCost > 0 else { return amount }
        return "\(amount) — at least; \(unknownCost) of \(runs) runs never reported a cost"
    }
}
