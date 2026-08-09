import Foundation

/// What a set of runs cost, and how much of that answer is actually known.
///
/// `unknownCost` is the load-bearing field. A run whose `totalCostUSD` was never
/// recorded — it crashed, it was cancelled before the result event, the app died
/// — must not read the same as a run that cost nothing. Collapsing the two is
/// exactly the bug `workingTreeChanged` avoids by distinguishing checked-and-
/// clean from never-checked, and here it would quietly understate a bill.
/// `Codable, Sendable, Hashable` since #209, which put a `Spend` inside a
/// `RepoBoardTally` and so inside a `RepoRow`: the row is `Hashable` and the
/// tally follows this codebase's convention for a new model type, and a
/// conformance is only as wide as its narrowest member. Three stored values,
/// all of them `Double` or `Int`, so both are synthesised.
public struct Spend: Codable, Sendable, Hashable {
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

/// A `Spend` together with the runs it could not have counted.
///
/// `BoardStore.spend(since:)` keys on `endedAt`, so a run still going
/// contributes nothing — stated at the query and then lost, because the only
/// thing a screen could ask was `Spend.isComplete`, which counts *finished*
/// runs whose cost went unrecorded and is therefore `true` throughout an
/// eight-lens analysis. The day read near zero while the money was being spent.
///
/// So the pair is the thing a reader is shown, for the reason `CardOutcome`
/// exists: a caller that could render the figure and forget the caveat is the
/// bug the type prevents. It is **not** stored and not sent anywhere —
/// `RepoBoardTally` still holds a bare `Spend`, and widening the wire for a
/// number that is only true for one instant would be worse than useless.
///
/// ⛔ **Never a dollar estimate for a run still going.** A count is a fact; a
/// projected cost is the invention `unknownCost` exists to prevent.
public struct SpendFigure: Sendable, Equatable {
    public var spend: Spend
    /// Runs going right now, which by definition have no `endedAt` yet.
    public var inFlight: Int

    public init(spend: Spend, inFlight: Int) {
        self.spend = spend
        self.inFlight = inFlight
    }

    /// The bare number, for the place a glance lands first.
    public func amount(locale: Locale = .current) -> String {
        MoneyFormat.usd(spend.totalUSD, locale: locale)
    }

    /// Whether the figure accounts for everything — asked here rather than of
    /// `Spend`, which can only answer the narrower half.
    public var isComplete: Bool { spend.isComplete && inFlight == 0 }

    /// One sentence covering both reasons a total can be a floor.
    public func sentence(locale: Locale = .current) -> String {
        guard inFlight > 0 else { return spend.sentence(locale: locale) }
        let flight =
            inFlight == 1
            ? "1 run in flight is not in this figure yet"
            : "\(inFlight) runs in flight are not in this figure yet"
        guard spend.unknownCost > 0 else {
            return "\(amount(locale: locale)) — at least; \(flight)"
        }
        return
            "\(amount(locale: locale)) — at least; \(spend.unknownCost) of \(spend.runs) runs never reported a cost, and \(flight)"
    }
}
