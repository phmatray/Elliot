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

    /// How many runs the figure is over, in words.
    ///
    /// Here so a caller does not invent a second plural, the same reason
    /// ``sentence(locale:)`` is here. `no runs` rather than `0 runs`, because a
    /// column reading `$0.00 · 0 runs` twice over is a row of noughts a reader
    /// stops seeing.
    public var runsSentence: String {
        switch runs {
        case 0: "no runs"
        case 1: "1 run"
        default: "\(runs) runs"
        }
    }

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

/// What has been spent since one day boundary: the total, and the same money
/// split by what the run was doing.
///
/// ⛔ **The boundary is a stored field, and that is the whole reason the type
/// exists.** The split and the total are two SQL aggregates, and the caller
/// refreshing them runs on every scheduler update — so two
/// `Calendar.current.startOfDay(for: Date())` reads, one per query, are two
/// different midnights either side of 00:00, and a screen showing both would
/// display a split that does not add up to its own total. `RunScheduler`'s
/// `spentTodayCache` already carries a warning about exactly that instant.
/// Keeping `since` here means the pair cannot be assembled from two boundaries
/// without saying so, and `BoardStore.daySpend(since:)` is the one place both
/// halves are read.
///
/// `byKind` answers the question the analysis setup screen raises and nothing
/// ever displayed: what a six-lens read costs, as against filing one issue
/// (#308).
public struct DaySpend: Sendable, Equatable {
    /// The instant both figures were measured from. Not decoration: it is the
    /// evidence that they are comparable.
    public var since: Date
    public var total: Spend
    public var byKind: [SkillKind: Spend]

    /// Nothing read yet. `distantPast` rather than `Date()` because a boundary
    /// nobody measured must not look like this morning's.
    public static let nothing = DaySpend(since: .distantPast, total: .nothing, byKind: [:])

    public init(since: Date, total: Spend, byKind: [SkillKind: Spend]) {
        self.since = since
        self.total = total
        self.byKind = byKind
    }

    /// What one skill cost in the period.
    ///
    /// Absent is `Spend.nothing`, which is honest: the query groups over runs
    /// that **ended** in the period, so a kind missing from it had none — zero
    /// runs, nothing unknown, nothing spent.
    public func spend(_ kind: SkillKind) -> Spend { byKind[kind] ?? .nothing }

    /// One figure per skill, in a fixed order, each carrying the runs of its own
    /// kind that are still going.
    ///
    /// ⛔ `SpendFigure`, never a bare `Spend`. `spend(since:)` keys on `endedAt`,
    /// so eight lenses in flight contribute **nothing** and the analyze-repo
    /// column reads `$0.00` — complete, and free — for the entire hour the money
    /// is being spent. That is the exact defect `SpendFigure` was minted for one
    /// figure up, and a per-skill breakdown is where it bites hardest, because
    /// the skill a reader is watching is the one whose runs are open.
    ///
    /// Every kind, including the ones nothing was spent on: a row that appears
    /// and vanishes as work moves is a row nobody can glance at, and `$0.00`
    /// over zero runs and zero in flight is simply true.
    ///
    /// `inFlight` is passed in rather than derived, because this type is a
    /// reading of the **past** — what a query returned — and what is going right
    /// now is a different fact from a different source. `RunningNow.countByKind`
    /// is that source.
    public func figures(inFlight: [SkillKind: Int]) -> [(kind: SkillKind, figure: SpendFigure)] {
        SkillKind.allCases.map { kind in
            (kind, SpendFigure(spend: spend(kind), inFlight: inFlight[kind] ?? 0))
        }
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
