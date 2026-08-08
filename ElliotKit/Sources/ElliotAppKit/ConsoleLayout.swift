import ElliotModel
import SwiftUI

/// The console's arithmetic, with no view attached to it.
///
/// `PanelLayout`'s vertical twin, and it exists for the same reason that file
/// gives at length: #47, #50, #52 and #53 shipped `.inspector()` three times,
/// green on `swift build` and `swift test` each time, and wrecked the window
/// each time, because `swift test` cannot see where anything sits on screen. So
/// the numbers live here where a test can pin them.
///
/// One thing is genuinely different from the horizontal case, and it decides the
/// shape of everything below. **The board scrolls sideways and does not scroll
/// down.** `PanelLayout.contentWidth` is allowed to exceed the window — it says
/// so, and the board frames the card and its panel instead. There is no such
/// escape vertically: a column that runs off the bottom is a column whose cards
/// cannot be reached, so height the console takes is height the board loses, and
/// the board's floor has to win every argument.
enum ConsoleLayout {

    // MARK: - Floors

    /// The least height at which a column is still a column.
    ///
    /// Its rail, its header, the list's own padding and two cards — two, not
    /// one, because a single card is a slot: with two the reader can see a
    /// stack, an order and the gap a drop lands in. Measured against the shipped
    /// metrics rather than chosen: `Metric.railHeight` + the column header +
    /// `Metric.columnListPadding` top and bottom + two cards and the spacing
    /// between them.
    static let minBoardHeight: CGFloat = 240

    /// The least height at which the console is worth unfolding: its own title
    /// row and about two rows of content.
    ///
    /// Below this it is a strip that says a screen is open without showing any
    /// of it — which is worse than the closed state it replaced, because it has
    /// spent the board's height to say nothing.
    static let minConsoleHeight: CGFloat = 140

    /// The share of the board's own height each designed console asks for.
    ///
    /// A share and not a constant, for the reason the panel is measured in
    /// columns: a fixed 300pt console reads as half the window on a laptop and
    /// as a strip on a display, and neither was drawn. What is drawn is "a third
    /// of the height" and "half of it".
    static func share(_ height: ConsoleHeight) -> CGFloat {
        switch height {
        case .short: 1.0 / 3.0
        case .tall: 1.0 / 2.0
        }
    }

    // MARK: - Heights

    /// The height available to the board and the console together: the window's
    /// content, less the status bar that neither of them may cover.
    ///
    /// The status bar is subtracted first and unconditionally. It is the strip
    /// the doors live in, and a console that could grow over its own doors would
    /// have no way back.
    static func availableHeight(contentHeight: CGFloat) -> CGFloat {
        max(0, contentHeight - Metric.statusBarHeight)
    }

    /// How tall the console actually is, in points.
    ///
    /// ⚠️ **The board's floor wins outright, and the console is allowed to come
    /// back smaller than `minConsoleHeight`.** That is deliberate and it is the
    /// whole reason this is a clamp in this order rather than the other: a
    /// `max(minConsoleHeight, …)` applied last would quietly grow the console
    /// past the board's floor at small window sizes and push cards off the
    /// bottom — the #47 shape, one axis over, and just as invisible to
    /// `swift test`. Asking "is there room" is `canOpen`'s job; this function
    /// only does the arithmetic, and it never inverts its own range.
    static func consoleHeight(_ height: ConsoleHeight, contentHeight: CGFloat) -> CGFloat {
        let available = availableHeight(contentHeight: contentHeight)
        let ceiling = max(0, available - minBoardHeight)
        return min(max(minConsoleHeight, available * share(height)), ceiling)
    }

    /// What is left for the board's row of columns.
    ///
    /// `nil` for a shut console means the board gets everything above the status
    /// bar, rather than a caller passing `.short` and subtracting a height that
    /// is not on screen.
    static func boardHeight(contentHeight: CGFloat, console: ConsoleHeight?) -> CGFloat {
        let available = availableHeight(contentHeight: contentHeight)
        guard let console else { return available }
        return max(0, available - consoleHeight(console, contentHeight: contentHeight))
    }

    /// Whether the window is tall enough to unfold the console at all.
    ///
    /// The gate the doors are disabled by. It asks the honest question — can the
    /// *shortest* console open while the board keeps its floor — so a reader on
    /// a short window is told the console will not fit rather than shown one
    /// that has eaten their cards.
    ///
    /// Keyed on `.short` and not on the reader's current height: a reader whose
    /// preference is `.tall` on a window that only fits `.short` should still get
    /// a console, at the height that fits. That is what `consoleHeight`'s ceiling
    /// already does; refusing here would take the screen away instead.
    static func canOpen(contentHeight: CGFloat) -> Bool {
        availableHeight(contentHeight: contentHeight) >= minBoardHeight + minConsoleHeight
    }

    /// The sentence a disabled door explains itself with.
    ///
    /// A sentence rather than a greyed-out control with nothing to say, because
    /// #151 settled this shape for the analysis toggle: *a toggle you cannot
    /// switch off is worse than one that opens onto an explanation*. The same
    /// holds for a door that will not open.
    static func refusal(contentHeight: CGFloat) -> String? {
        guard !canOpen(contentHeight: contentHeight) else { return nil }
        let short = Int((minBoardHeight + minConsoleHeight + Metric.statusBarHeight).rounded())
        return """
            The window is too short to unfold a screen over the board — \
            make it at least \(short)pt tall and this opens.
            """
    }

    // MARK: - Resizing

    /// Which height a drag on the console's **top** edge lands on when released.
    ///
    /// `translation` is the drag's vertical component as `DragGesture` reports
    /// it — downwards positive — so dragging *up* grows the console and the sign
    /// is flipped once, here, rather than at the gesture. The console has only
    /// one grabbable edge, unlike the panel, so there is no `opensLeft` twin to
    /// this: its bottom edge is the status bar and its doors.
    ///
    /// A drag of zero returns the height unchanged at either setting, so a click
    /// on the handle that never moves can never resize the console behind the
    /// reader's back — the property `PanelLayout.snappedSpans` states and this
    /// one has to hold too.
    static func snapped(
        from height: ConsoleHeight, translation: CGFloat, contentHeight: CGFloat
    ) -> ConsoleHeight {
        // A window with no room is not one to snap against; the reader's
        // preference is left alone rather than repaired to something arbitrary.
        guard canOpen(contentHeight: contentHeight) else { return height }

        let grown = consoleHeight(height, contentHeight: contentHeight) - translation
        let toShort = abs(grown - consoleHeight(.short, contentHeight: contentHeight))
        let toTall = abs(grown - consoleHeight(.tall, contentHeight: contentHeight))

        // Dead level — either the drag ended exactly between the two, or the
        // window is short enough that the ceiling has collapsed both designs
        // onto the same height. Staying put is the only answer that does not
        // pick for the reader.
        if toShort == toTall { return height }
        return toShort < toTall ? .short : .tall
    }
}
