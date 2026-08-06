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

/// One half of the panel's body: what the card *says*, or what has been *run*
/// against it.
///
/// Two cases and no more. At two spans they are named by a segmented switch a
/// column and a bit wide, and a third tab would either truncate or wrap — and a
/// pane a reader cannot reach is the exact failure the switch is here to avoid.
enum PanelPane: String, CaseIterable, Hashable, Sendable, Identifiable {
    case issue
    case runs

    var id: String { rawValue }

    /// The bare word. The switch appends the issue number and the run count to
    /// it, because those belong to the card rather than to the pane.
    var displayName: String {
        switch self {
        case .issue: "Issue"
        case .runs: "Runs"
        }
    }
}

/// One block of the panel's **header**, in reading order.
///
/// A separate type from `PanelPane`, and that separation is the point rather
/// than tidiness: `headerRegions` returns these and `panes` returns those, so
/// `.mergeConfirmation` **cannot be placed inside a pane** — not "is not", but
/// cannot be, at compile time.
///
/// #85 moved the merge confirmation onto this panel deliberately above
/// everything else on it, because it is the only thing there waiting on the
/// reader and the one act in the product that cannot be undone. At two spans a
/// pane is hidden; a confirmation drawn inside the Issue pane while the reader
/// sits on Runs is an armed merge with nowhere to confirm it — and
/// `armPendingMerge` opens the panel *in order to* show it.
enum PanelHeaderRegion: Hashable, Sendable {
    case mergeConfirmation
    case nextStep
    case paneSwitch
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

    // MARK: - What the panel shows

    /// Whether both panes fit side by side.
    ///
    /// Three spans is the mockup's two-pane body. Below that the panel is barely
    /// more than a column wide, and two panes in it would each be narrower than
    /// the card they describe.
    static func showsBothPanes(spans: Int) -> Bool { spans >= 3 }

    /// The panes the panel actually builds, in reading order.
    ///
    /// One entry when only one fits, and it is the selected one — **not** both
    /// with one hidden. Criterion 5: the pane that is not showing has to be
    /// absent from the view tree, because a hidden-but-present pane is still
    /// reachable by VoiceOver, and a reader who chose Runs would be read the
    /// issue body they did not ask for.
    static func panes(spans: Int, selected: PanelPane) -> [PanelPane] {
        showsBothPanes(spans: spans) ? PanelPane.allCases : [selected]
    }

    /// What the panel draws above its body, in reading order.
    ///
    /// ⚠️ **The selected pane is deliberately not a parameter.** That absence is
    /// the guarantee: no header block can vary with which pane is showing, so
    /// the merge confirmation cannot be hidden by the switch. Nothing here
    /// avoids the bug — the signature makes it unwritable.
    ///
    /// `.mergeConfirmation` comes first for the same reason it lives here at
    /// all, and it is the one block that survives edit mode: the editor replaces
    /// the body, so there is no pane to switch and no next step to take until it
    /// closes, but an armed merge is still waiting on an answer.
    static func headerRegions(
        spans: Int, isEditing: Bool, isMergePending: Bool, hasNextStep: Bool
    ) -> [PanelHeaderRegion] {
        var regions: [PanelHeaderRegion] = []
        if isMergePending { regions.append(.mergeConfirmation) }
        guard !isEditing else { return regions }
        if hasNextStep { regions.append(.nextStep) }
        // Exactly when something is hidden. A switch offering a choice between
        // two panes that are both already on screen is furniture.
        if !showsBothPanes(spans: spans) { regions.append(.paneSwitch) }
        return regions
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

    /// Where a slot's leading edge falls inside the board's row, or `nil` if
    /// that slot is not in this order at all.
    ///
    /// The row is an `HStack` of **known** widths — five columns of one width,
    /// one panel of another, one gutter between each pair and one more as the
    /// row's own padding — so where a slot sits is arithmetic rather than a
    /// measurement. That matters for more than tidiness: framing runs in the
    /// same update that inserts the panel, and a measurement taken then
    /// describes the row as it was a moment ago. This answers before the layout
    /// has run.
    ///
    /// `nil` rather than `0` for a slot that is not there: zero is a position,
    /// and a caller that scrolled to it would scroll to the leading edge of the
    /// board and look like it had worked.
    static func minX(
        of target: BoardSlot, in slots: [BoardSlot],
        columnWidth: CGFloat, panelWidth: CGFloat, gutter: CGFloat = Metric.gutter
    ) -> CGFloat? {
        guard let index = slots.firstIndex(of: target) else { return nil }
        // The row's own padding is one gutter, so the first slot starts there.
        var x = gutter
        for slot in slots[..<index] {
            x += (slot == .panel ? panelWidth : columnWidth) + gutter
        }
        return x
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
