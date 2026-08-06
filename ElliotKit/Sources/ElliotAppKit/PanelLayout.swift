import ElliotModel
import SwiftUI

/// One slot in the board's single ordered list of children.
///
/// `.panel` carries **one constant identity** on purpose. Emitting the panel
/// conditionally inside a `ForEach` over `Column.allCases` would give it a
/// different identity per origin column, and under the stack-wide
/// `.animation(…, value: model.selectedCardID)` that is a remove plus an
/// insert — two panels and two carets mid-transition. As one case it is
/// re-ordered, never rebuilt.
enum BoardSlot: Hashable {
    case column(ElliotModel.Column)
    case panel
}

/// The board's arithmetic, with no view attached to it.
///
/// This exists because of #47, #50, #52 and #53: `.inspector()` shipped three
/// times, green on `swift build` and `swift test` each time, and wrecked the
/// window each time. `swift test` cannot see where anything sits on screen. So
/// the *numbers* the layout is built from live here — pure, no view, no
/// environment, no clock — where a test can pin them, and the views above only
/// place what these functions return.
///
/// Nothing in here reads a preference or a window: every input is a parameter.
enum PanelLayout {

    // MARK: - Widths

    /// Today's column formula, extracted verbatim from `BoardView.columns` so
    /// the panel's width and the scroll predicate derive from the *same* number
    /// the columns do rather than from a second copy of it.
    ///
    /// `max(minColumnWidth, (boardWidth − gutter · 6) / 5)`. The floor only
    /// binds below a 1190pt window — at the 1640pt default the columns are
    /// 316pt, not 226 — which is what makes the panel 968pt and not 698.
    static func columnWidth(boardWidth: CGFloat) -> CGFloat {
        let count = CGFloat(ElliotModel.Column.allCases.count)
        let available = boardWidth - Metric.gutter * (count + 1)
        return max(Metric.minColumnWidth, available / count)
    }

    /// The panel measured **in columns**: `spans` of them plus the gutters
    /// between. That is what makes it read as being *of* the column it came
    /// from — a constant 344pt beside 316pt columns reads as 1.1 columns and
    /// says nothing.
    ///
    /// `spans` is a reader preference (2 or 3), not a function of window width;
    /// it is clamped to at least 1 only so a nonsense value cannot hand SwiftUI
    /// a negative frame.
    static func panelWidth(
        columnWidth: CGFloat, spans: Int, gutter: CGFloat = Metric.gutter
    ) -> CGFloat {
        let spans = CGFloat(max(1, spans))
        return spans * columnWidth + (spans - 1) * gutter
    }

    /// What the board's `HStack` actually measures: five columns plus the panel
    /// and seven gutters, or five columns and six gutters when nothing is
    /// selected. `spans: nil` means closed.
    ///
    /// The closed case is exactly today's layout — at 1640pt it comes to 1640 —
    /// so a scroll predicate derived from this is a no-op with the panel shut.
    /// With the panel open it is 1.6–1.7× the viewport at every window size the
    /// app allows, which is why the board scrolls whenever the panel is open.
    static func contentWidth(boardWidth: CGFloat, spans: Int?) -> CGFloat {
        let count = CGFloat(ElliotModel.Column.allCases.count)
        let columns = columnWidth(boardWidth: boardWidth) * count
        guard let spans else { return columns + Metric.gutter * (count + 1) }
        let panel = panelWidth(columnWidth: columnWidth(boardWidth: boardWidth), spans: spans)
        return columns + panel + Metric.gutter * (count + 2)
    }

    // MARK: - Order

    /// Whether the panel opens to this column's **left**.
    ///
    /// Keyed on `boardIndex` — "which edge of the board is this" is positional.
    /// Deliberately not on `naturalNext == nil`, which is the rule engine's
    /// transition matrix: the two coincide today only because both read off
    /// `allCases`, and keying layout on the matrix would put the caret on the
    /// wrong edge the day a terminal-but-not-last column exists.
    static func opensLeft(of column: ElliotModel.Column) -> Bool {
        column.boardIndex == ElliotModel.Column.allCases.count - 1
    }

    /// The columns in board order with `.panel` inserted immediately after the
    /// origin column — or immediately before it, for the column that opens
    /// left. Six entries when a card is selected, five otherwise, and always
    /// all five columns.
    static func boardOrder(selected: ElliotModel.Column?) -> [BoardSlot] {
        let columns = ElliotModel.Column.allCases
        guard let selected else { return columns.map(BoardSlot.column) }

        var slots: [BoardSlot] = []
        slots.reserveCapacity(columns.count + 1)
        let flipped = opensLeft(of: selected)
        for column in columns {
            if column == selected, flipped { slots.append(.panel) }
            slots.append(.column(column))
            if column == selected, !flipped { slots.append(.panel) }
        }
        return slots
    }

    // MARK: - Caret and tether

    /// Where the caret sits inside the panel, in the panel's own coordinates.
    ///
    /// `clamp(cardMidY − panelMinY, inset, panelHeight − inset)` — the inset
    /// keeps the caret off the panel's rounded corners, so a card scrolled near
    /// either end still points at the panel rather than at a corner radius.
    ///
    /// The upper bound is floored at `inset` so a panel shorter than twice the
    /// inset cannot invert the range and return the *larger* of two swapped
    /// bounds.
    static func caretY(
        cardMidY: CGFloat, panelMinY: CGFloat, panelHeight: CGFloat, inset: CGFloat = 26
    ) -> CGFloat {
        let upper = max(inset, panelHeight - inset)
        return min(max(cardMidY - panelMinY, inset), upper)
    }

    /// Whether the caret has lost its card — the tether goes to opacity 0 and
    /// the caret to 0.35.
    ///
    /// True at *and* past the inset on both edges, and true when there is no
    /// card rect at all. Cards live in a `LazyVStack`, so a card scrolled far
    /// enough is never built and its geometry reporter simply stops firing.
    /// Reading that absence as `y = 0` would aim the caret at the top of the
    /// panel and assert a card is there — so `nil` reads the same as out of
    /// band, which is what it means.
    static func isDetached(
        cardMidY: CGFloat?, listTop: CGFloat, listBottom: CGFloat, inset: CGFloat = 6
    ) -> Bool {
        guard let cardMidY else { return true }
        return !(cardMidY > listTop + inset && cardMidY < listBottom - inset)
    }

    /// How far the board scrolls to frame the origin column and its panel: the
    /// leading edge of the **pair**, minus a lead so the pair does not sit flush
    /// against the window edge.
    ///
    /// Which view is the leading one flips with the panel: after the origin
    /// column the column leads, before it the panel does. Using `originMinX` in
    /// the flipped case would scroll past the panel and leave it off-screen to
    /// the left. Never negative — a negative content offset is not a position.
    static func frameOffsetX(
        originMinX: CGFloat, panelMinX: CGFloat, flipped: Bool, lead: CGFloat = 96
    ) -> CGFloat {
        max(0, (flipped ? panelMinX : originMinX) - lead)
    }

    /// How far the tether reaches from the panel's edge to the card: the gutter
    /// between the two views plus the column list's own horizontal padding.
    ///
    /// Named rather than written as 18 because the point of the tether is that
    /// it *touches* the card. Left bare it would stop touching — and read as a
    /// dash near the card instead of a line to it — the day either literal
    /// moves.
    static let tetherReach: CGFloat = Metric.gutter + Metric.columnListPadding
}
