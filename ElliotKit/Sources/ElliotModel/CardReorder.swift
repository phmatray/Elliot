import Foundation

/// What a drop onto a card means.
///
/// Three outcomes and no fourth, which is the point of the type: a drop either
/// does nothing, places a card inside the column it is already in, or crosses
/// columns — and crossing columns is the one that may file an issue, open a pull
/// request or merge one. Keeping them as cases means the view cannot invent a
/// fourth reading, and cannot quietly turn the third into the second.
public enum DropPlacement: Sendable, Hashable {
    /// The drop changes nothing. A card dropped on itself is the case this
    /// exists for, and it is not the same as "place it where it already is":
    /// see `CardReorder.placement`.
    case none

    /// Place the card between two neighbours in the column it is already in.
    /// `nil` on either side means there is no neighbour that way.
    case reorder(previous: Double?, next: Double?)

    /// Cross into another column **first** — with everything that implies — and
    /// only then place it. The neighbours are the ones it will land between.
    case moveThenReorder(to: Column, previous: Double?, next: Double?)
}

/// Where a dropped card lands.
///
/// Pure, and in `ElliotModel` rather than in the drop closure that will call it,
/// because it is a rule: the view dispatches this answer, it does not reach it.
/// That also makes the two guards #47's review called out — the self-drop, and
/// crossing columns before placing — things `swift test` can see, in a change
/// whose other half it cannot.
public enum CardReorder {

    /// The gap `BoardService.reorder` leaves either side of a card when there is
    /// no neighbour to average against. Named here because the placement and the
    /// writer have to agree about it, and a literal in two files is two chances
    /// to disagree.
    public static let gap: Double = 1024

    /// What dropping `moving` onto `target` inside `column` should do.
    ///
    /// `columnCards` is the destination column's cards in the order the board
    /// draws them; the moving card is filtered out here rather than by the
    /// caller, so the neighbours are the ones it will actually sit between.
    /// Passing them already-sorted is the caller's job — this does not re-sort,
    /// for the same reason the move history does not: the board's order is the
    /// one on screen.
    ///
    /// A `nil` target means "no card was under the cursor", which is an append.
    public static func placement(
        moving: Card, onto target: Card?, in column: Column, columnCards: [Card]
    ) -> DropPlacement {
        // The guard the whole issue turns on. Without it the card is filtered
        // out of `ordered`, `firstIndex` finds nothing, the index falls through
        // to `ordered.count`, and the card is sent to the **bottom of its own
        // column** — a silent data change from a gesture that should do nothing.
        //
        // Answered as `.none` rather than as a placement between its current
        // neighbours: those are two different claims, and only this one is
        // guaranteed to write nothing at all.
        if let target, target.id == moving.id { return .none }

        let ordered = columnCards.filter { $0.id != moving.id }
        let index = target.flatMap { t in ordered.firstIndex { $0.id == t.id } } ?? ordered.count
        let previous = index > 0 ? ordered[index - 1].orderIndex : nil
        let next = index < ordered.count ? ordered[index].orderIndex : nil

        return moving.column == column
            ? .reorder(previous: previous, next: next)
            : .moveThenReorder(to: column, previous: previous, next: next)
    }

    /// The `orderIndex` a placement resolves to.
    ///
    /// The same arithmetic `BoardService.reorder` performs, exposed so a test can
    /// state the *consequence* of a placement rather than only its shape — that
    /// dropping above the first card really does land before it, rather than
    /// merely reporting `previous: nil`.
    public static func index(previous: Double?, next: Double?) -> Double {
        switch (previous, next) {
        case (let p?, let n?): (p + n) / 2
        case (let p?, nil): p + gap
        case (nil, let n?): n - gap
        case (nil, nil): 0
        }
    }
}
