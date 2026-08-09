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
    /// The analysis, pinned at the leading edge of the row.
    ///
    /// Before Backlog because that is where what it produces lands: accepting a
    /// proposal makes a card in the column immediately to its right. It has no
    /// origin column and therefore no caret, no tether and no flip — the whole
    /// second half of this file is about a panel that belongs to a *card*, and
    /// this one belongs to the board.
    ///
    /// One constant identity, for the reason `.panel` has one.
    case analysis
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

    /// What the board's `HStack` actually measures: five columns, plus each
    /// panel that is open, plus one gutter per slot and one more for the row's
    /// own padding. A `nil` span means that panel is shut.
    ///
    /// The both-shut case is exactly today's layout — at 1640pt it comes to
    /// 1640 — so a scroll predicate derived from this is a no-op with nothing
    /// open. With either panel open it is well past the viewport at every
    /// window size the app allows, which is why the board scrolls whenever one
    /// is open.
    ///
    /// ⚠️ `analysisSpans` is **required, not defaulted**. A default is how a
    /// caller silently measures a row that is not the one on screen, which is
    /// exactly the failure `BoardFraming`'s doc comment describes for its three
    /// missed triggers — and the old predicate already shipped that bug once,
    /// reporting "everything fits" over content 1.6× the viewport.
    static func contentWidth(boardWidth: CGFloat, spans: Int?, analysisSpans: Int?) -> CGFloat {
        let column = columnWidth(boardWidth: boardWidth)
        let count = CGFloat(ElliotModel.Column.allCases.count)
        var total = column * count
        var slots = count
        for open in [spans, analysisSpans] {
            guard let open else { continue }
            total += panelWidth(columnWidth: column, spans: open)
            slots += 1
        }
        return total + Metric.gutter * (slots + 1)
    }

    // MARK: - Resizing

    /// The only two widths the panel is designed at.
    ///
    /// Not a continuous range, and that is the point: at `narrow` one pane fits
    /// behind a switch and at `wide` both fit side by side
    /// (`showsBothPanes(spans:)`), and every width between them is a panel that
    /// is too wide for one pane and too narrow for two. So the drag handle
    /// snaps rather than tracks — a reader who lets go anywhere gets one of the
    /// two layouts that were designed, never a stuck middle.
    ///
    /// The pair itself is `Preferences.spanChoices` and is *referred* to here
    /// rather than restated, because the same two numbers now decide two things
    /// in two targets: which layout a drag lands on, and which stored value is
    /// one a reader could have produced (`Preferences.clamped()`). Writing `2`
    /// and `3` in both would be a rule with two implementations — the shape this
    /// repository has paid for four times.
    static let spanChoices = Preferences.spanChoices

    /// Which span a drag on the panel's **outer** edge lands on when it is
    /// released.
    ///
    /// `translation` is the drag's horizontal component in the board's own
    /// coordinates — rightwards positive, exactly what `DragGesture` reports.
    ///
    /// ⚠️ `opensLeft` is not a detail. The handle lives on whichever edge is
    /// *not* against the origin column — the trailing edge normally, the
    /// leading edge for the flipped column (`opensLeft(of:)`) — so the same
    /// physical gesture, "drag the edge away from the card", is a rightward
    /// drag in one case and a leftward drag in the other. Without the flip a
    /// reader on Done would find the handle working backwards.
    ///
    /// A drag of zero returns `spans` unchanged at either setting, so a click
    /// on the handle that never moves can never resize the panel behind the
    /// reader's back.
    static func snappedSpans(
        from spans: Int,
        translation: CGFloat,
        columnWidth: CGFloat,
        opensLeft: Bool,
        gutter: CGFloat = Metric.gutter
    ) -> Int {
        // A zero or negative column width is not a board; there is nothing to
        // snap against and the reader's preference is left alone.
        guard columnWidth > 0 else { return spans }

        let widening = opensLeft ? -translation : translation
        let width = panelWidth(columnWidth: columnWidth, spans: spans, gutter: gutter) + widening

        let narrow = panelWidth(columnWidth: columnWidth, spans: spanChoices.narrow, gutter: gutter)
        let wide = panelWidth(columnWidth: columnWidth, spans: spanChoices.wide, gutter: gutter)
        let toNarrow = abs(width - narrow)
        let toWide = abs(width - wide)

        // Dead level — the drag ended exactly half a column short of either.
        // Staying put is the only answer that does not pick for the reader; a
        // span outside the two choices (which the menu cannot produce, but an
        // integer preference can hold) resolves to the default instead.
        if toNarrow == toWide {
            return spans == spanChoices.narrow || spans == spanChoices.wide ? spans : spanChoices.wide
        }
        return toNarrow < toWide ? spanChoices.narrow : spanChoices.wide
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
    /// left — and `.analysis` pinned ahead of all of them when it is showing.
    /// Always all five columns, in order, whatever else is in the row.
    ///
    /// The analysis slot is unconditionally first and never flips: it has no
    /// origin column to be beside, and the column it belongs *next to* is the
    /// one it fills.
    static func boardOrder(selected: ElliotModel.Column?, analysisOpen: Bool) -> [BoardSlot] {
        let columns = ElliotModel.Column.allCases
        var slots: [BoardSlot] = analysisOpen ? [.analysis] : []
        slots.reserveCapacity(columns.count + 2)

        guard let selected else { return slots + columns.map(BoardSlot.column) }

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
        columnWidth: CGFloat, panelWidth: CGFloat, analysisWidth: CGFloat,
        gutter: CGFloat = Metric.gutter
    ) -> CGFloat? {
        guard let index = slots.firstIndex(of: target) else { return nil }
        // The row's own padding is one gutter, so the first slot starts there.
        var x = gutter
        for slot in slots[..<index] {
            x += slotWidth(
                slot, columnWidth: columnWidth,
                panelWidth: panelWidth, analysisWidth: analysisWidth) + gutter
        }
        return x
    }

    /// How wide one slot is.
    ///
    /// Extracted from the `slot == .panel ? panelWidth : columnWidth` ternary
    /// `minX` used to carry. With three slot kinds that ternary silently
    /// measures the analysis panel as a *column* — a row wrong by hundreds of
    /// points, with nothing on screen to say so and every test still green,
    /// because both halves of a two-way ternary stay type-correct when a third
    /// case appears.
    static func slotWidth(
        _ slot: BoardSlot, columnWidth: CGFloat, panelWidth: CGFloat, analysisWidth: CGFloat
    ) -> CGFloat {
        switch slot {
        case .analysis: analysisWidth
        case .column: columnWidth
        case .panel: panelWidth
        }
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
    ///
    /// **The lead yields to the pair** (#93). It used to be a fixed 96pt, which
    /// at the 1000pt minimum window pushed 30pt of the panel's trailing edge —
    /// and the resize handle that lives on it — off screen: the column floor
    /// binds at 226pt there, so at three spans the pair is 934pt and only 66pt
    /// of lead actually fits. The lead is the part that is decoration, so the
    /// lead is the part that gives; showing less of the previous column is a
    /// smaller loss than showing none of the panel's edge.
    ///
    /// Both widths are taken rather than a single `pairWidth`, because which end
    /// trails flips with `flipped` — computing it here keeps that answer in the
    /// one place that already knows, instead of in every caller.
    ///
    /// `panelMinX` is optional because a shut panel is a real case and its pair
    /// is the column **by itself**. It used to be passed as `originMinX` with a
    /// note calling the fallback unreachable; that was true while no width was
    /// read, and stopped being true the moment the pair's extent started to
    /// matter — a shut panel would otherwise be measured as a column-and-a-panel
    /// wide and clamp a lead it did not need to.
    ///
    /// When the pair is wider than the viewport the lead goes to zero and the
    /// leading edge sits flush: the remaining overflow is the panel genuinely
    /// not fitting, which no offset can fix, and framing the leading edge is the
    /// most of it anyone can see.
    static func frameOffsetX(
        originMinX: CGFloat, panelMinX: CGFloat?, flipped: Bool,
        columnWidth: CGFloat, panelWidth: CGFloat, viewportWidth: CGFloat,
        lead: CGFloat = 96
    ) -> CGFloat {
        let leadingMinX: CGFloat
        let trailingMaxX: CGFloat
        switch (panelMinX, flipped) {
        case (nil, _):
            (leadingMinX, trailingMaxX) = (originMinX, originMinX + columnWidth)
        case (let panelMinX?, false):
            (leadingMinX, trailingMaxX) = (originMinX, panelMinX + panelWidth)
        case (let panelMinX?, true):
            (leadingMinX, trailingMaxX) = (panelMinX, originMinX + columnWidth)
        }

        let affordable = max(0, min(lead, viewportWidth - (trailingMaxX - leadingMinX)))
        return max(0, leadingMinX - affordable)
    }

    /// How far the tether reaches from the panel's edge to the card: the gutter
    /// between the two views plus the column list's own horizontal padding.
    ///
    /// Named rather than written as 18 because the point of the tether is that
    /// it *touches* the card. Left bare it would stop touching — and read as a
    /// dash near the card instead of a line to it — the day either literal
    /// moves.
    static let tetherReach: CGFloat = Metric.gutter + Metric.columnListPadding

    /// Whether the panel draws the card's labels outside edit mode.
    ///
    /// Criterion 4 is that the labels are readable *without* opening an editor —
    /// a decision the board does not show is the complaint this whole feature
    /// starts from. So: shown whenever there are any, and nothing at all when
    /// there are not. An always-present caption over an empty rail reads as
    /// something that failed to load, which is the opposite of informative.
    ///
    /// Here rather than as an `if` in the panel's body for this file's usual
    /// reason: `swift test` can hold this and cannot hold a `ViewBuilder`.
    static func showsLabels(_ card: Card) -> Bool { !card.labels.isEmpty }
}
