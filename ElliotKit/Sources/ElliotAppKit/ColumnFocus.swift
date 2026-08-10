import Foundation
import SwiftUI

/// A card that has just arrived somewhere, and which arrival it was.
///
/// The stamp is load-bearing: a bare `UUID?` would not fire `onChange` when the
/// same card lands twice in a row, which is the ordinary case of walking one
/// card across the board.
///
/// Top-level rather than nested inside `AppModel`, which is where it lived.
/// `AppModel` is `@MainActor` and a type nested in it inherits that isolation,
/// so a rule that reads `cardID` could not stay pure. ``ColumnFocus`` below is
/// that rule, and being able to ask it a question in a test without a main-actor
/// hop is the whole reason it is out here.
public struct CardLanding: Equatable, Sendable {
    public var cardID: UUID
    public var stamp: UUID

    public init(cardID: UUID, stamp: UUID) {
        self.cardID = cardID
        self.stamp = stamp
    }
}

/// What a column must bring on screen, as **one** value.
///
/// Two things ask for it and they arrive *together*: a drop lands a card and
/// selects it — the drag selected it on the way out of its old column, and the
/// card's arrival makes both true of this column in the same update. Two
/// `onChange` handlers on one `ScrollViewProxy` would animate that column twice
/// for one gesture. So this is the shape `BoardFraming` already uses for the
/// row's horizontal scroll: one `Equatable` value, one handler, and the
/// *previous* value deciding which half of it moved.
///
/// ⛔ Only cards this column is **drawing** appear here, which is the other half
/// of #277. A `LazyVStack` never built a row for a card inside a folded group or
/// past Done's horizon, so `scrollTo` would have nothing to scroll to and would
/// silently do nothing — the same false negative this repository keeps paying
/// for. `ColumnRows` is the one answer to what is drawn; this asks it rather
/// than holding a second opinion.
struct ColumnFocus: Equatable, Sendable {
    /// The most recent landing anywhere, kept only when this column is drawing
    /// that card.
    var landing: CardLanding?

    /// The selected card, kept only when this column is drawing it.
    var selected: UUID?

    static func of(landing: CardLanding?, selection: UUID?, drawn: ColumnRows) -> ColumnFocus {
        ColumnFocus(
            landing: landing.flatMap { drawn.draws($0.cardID) ? $0 : nil },
            selected: drawn.draws(selection) ? selection : nil
        )
    }

    /// Where to scroll, given what this column had to show a moment ago — or
    /// `nil` when neither half moved and the list should stay where the reader
    /// left it.
    ///
    /// A landing outranks a selection because a drop is both, and centring the
    /// card that just arrived is the stronger answer. It only outranks it *when
    /// it is the thing that changed*: `lastLanded` is never cleared, so a
    /// landing that keeps winning after the fact would pin the column to a card
    /// the reader has since arrowed away from — which is the bug a naive
    /// "landing first" ordering hides until the second keystroke.
    func target(from previous: ColumnFocus) -> Target? {
        if let landing, landing != previous.landing {
            return Target(cardID: landing.cardID, anchor: .center)
        }
        if let selected, selected != previous.selected {
            return Target(cardID: selected, anchor: nil)
        }
        return nil
    }

    /// A card to scroll to, and how far.
    struct Target: Equatable {
        var cardID: UUID

        /// `.center` for a card that has just landed: it teleported here from
        /// another column and centring is what says "there it is".
        ///
        /// `nil` for a selection step, and that is `ScrollViewProxy`'s "scroll
        /// as little as possible to make this visible". Centring on every arrow
        /// press would drag the whole list under a reader who can already see
        /// the card they just moved to.
        var anchor: UnitPoint?
    }
}
