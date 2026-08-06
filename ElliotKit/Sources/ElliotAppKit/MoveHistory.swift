import ElliotModel
import Foundation

/// One move, as the panel draws it: where the card went, when, who moved it,
/// and what that move started.
struct MoveHistoryRow: Identifiable, Hashable {
    /// The audit's own id. Not a fresh one — a row is a rendering of a stored
    /// move, and sharing the identity keeps the two talking about one event.
    var id: UUID
    var from: ElliotModel.Column
    var to: ElliotModel.Column
    var at: Date
    /// `MoveOrigin.historyLabel` — a fragment for a tabular line, never the
    /// header's sentence. See `Consequence.swift` for why those are two things.
    var origin: String
    /// `nil` only when the move started nothing at all. A move that *did* start
    /// a run always carries a ref, even when the run cannot be named.
    var run: RunRef?

    /// A run a move started.
    ///
    /// `skillName` is optional and the `RunRef` itself is not, which is the
    /// whole design: "this move started something I cannot name" and "this move
    /// started nothing" are different facts, and collapsing them would let the
    /// panel claim the second when the first is true.
    struct RunRef: Hashable {
        var id: UUID
        var skillName: String?
    }
}

/// Folds a card's stored moves and its loaded runs into rows.
///
/// Pure, and deliberately not a view: `swift test` cannot see the block on
/// screen, so every decision about *what it says* lives here where it can be
/// pinned. No clock — a row carries its `Date` and the view ages it, so this
/// function returns the same rows in a test as it does at midnight.
enum MoveHistory {

    /// What `AppModel` asks the store for. Named here beside `isCapped`, which
    /// is the only thing that gives the number meaning.
    static let auditLimit = 100

    /// Newest first, straight through from the store's `ORDER BY at DESC`.
    ///
    /// Not re-sorted: the store already ordered them, and a second ordering
    /// here would be a second thing to keep in agreement — with the list a test
    /// pins no longer being the list SQLite returns.
    ///
    /// The runs are indexed once rather than searched per audit; with 100
    /// audits against 20 runs the difference is not the point, having one
    /// obvious cost is.
    nonisolated static func rows(audits: [MoveAudit], runs: [SkillRun]) -> [MoveHistoryRow] {
        let byID = Dictionary(runs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return audits.map { audit in
            MoveHistoryRow(
                id: audit.id,
                from: audit.from,
                to: audit.to,
                at: audit.at,
                origin: audit.origin.historyLabel,
                // The audit is the authority on *whether* a run started; the
                // loaded window is only the authority on its name.
                run: audit.runID.map {
                    MoveHistoryRow.RunRef(id: $0, skillName: byID[$0]?.kind.skillName)
                })
        }
    }

    /// True when the read came back at the store's cap, so the block can say
    /// the list may be partial rather than presenting it as complete.
    ///
    /// `>=` rather than `==`: a count past the limit is still "you may be
    /// missing some", and the reassuring answer should never be the one a
    /// surprising number falls into.
    nonisolated static func isCapped(count: Int, limit: Int = auditLimit) -> Bool {
        count >= limit
    }
}
