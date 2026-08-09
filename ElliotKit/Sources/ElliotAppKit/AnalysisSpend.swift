import ElliotModel
import Foundation

/// What one analysis cost, and how much of that it actually knows.
///
/// The setup footer's whole consequence line is about spend — *"Reads the
/// repository 6 times — one run per lens"* — and `LensRunRow`'s cost chip
/// carries a comment claiming to settle that warning. But the lens strip
/// collapses itself once every run is terminal, and the collapsed state is the
/// one the reader sits in for the entire triage: the summary kept lenses, kept,
/// dropped, recovered and the repository-edited alarm, and dropped the cost. So
/// the one number the setup form promised was the one missing once the analysis
/// was over.
///
/// Pure, and a type rather than a `reduce` in the view, for one reason:
/// `totalCostUSD` is optional per run and **a nil is not a zero**. A total that
/// silently omitted two runs would read as the full spend — the false-negative
/// family this codebase has now named six times, and the same tri-state
/// discipline `workingTreeChanged` is written around a few lines from where
/// this is rendered.
enum AnalysisSpend {

    /// A total, and what it does not cover.
    struct Total: Equatable, Sendable {
        /// The sum of the costs that *were* recorded.
        var usd: Double
        /// How many runs had no cost recorded at all.
        var unrecorded: Int

        /// True when the figure is a floor rather than the whole spend.
        var isPartial: Bool { unrecorded > 0 }
    }

    /// `nil` when nothing can be totalled.
    ///
    /// Not `Total(usd: 0, unrecorded: n)`: rendering `$0.00` for an analysis
    /// whose runs simply have not reported yet is a claim that it was free.
    /// Absent is the honest rendering of "no reading", and it is the state a
    /// still-running analysis is in.
    static func of(_ runs: [SkillRun]) -> Total? {
        let costs = runs.compactMap(\.totalCostUSD)
        guard !costs.isEmpty else { return nil }
        return Total(usd: costs.reduce(0, +), unrecorded: runs.count - costs.count)
    }

    /// The chip's text. A trailing `+` on a partial total, because a tooltip is
    /// not "saying so plainly" — the mark has to survive on screen.
    static func label(_ total: Total) -> String {
        total.isPartial ? "\(MoneyFormat.usd(total.usd))+" : MoneyFormat.usd(total.usd)
    }

    /// What the chip says on hover, which is where the count of missing runs
    /// belongs — it explains the `+` rather than repeating the number.
    static func help(_ total: Total) -> String {
        guard total.isPartial else { return "What this analysis cost" }
        return total.unrecorded == 1
            ? "What this analysis cost so far — 1 run has reported no cost"
            : "What this analysis cost so far — \(total.unrecorded) runs have reported no cost"
    }
}
