import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// What a column scrolls to, and how far.
///
/// The scroll itself is layout and cannot be seen from here — that is the gap
/// CLAUDE.md records three merges against. What *can* be held is the decision:
/// which of the two things asking (a landing, a selection) moved, whether the
/// column is drawing that card at all, and whether one gesture produces one
/// scroll or two.
@Suite("Column focus")
struct ColumnFocusTests {

    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)
    private let repoID = UUID()

    private func card(_ title: String, order: Double = 0) -> Card {
        Card(
            repoID: repoID, title: title, orderIndex: order,
            columnEnteredAt: epoch, createdAt: epoch, updatedAt: epoch
        )
    }

    private func drawn(_ cards: [Card]) -> ColumnRows {
        ColumnRows.build(.flat(cards), foldedRepoIDs: [], foldedDays: [], selection: nil)
    }

    /// The collision the issue names: a drag selects the card on its way out of
    /// the old column and the drop lands it here, so from *this* column's side
    /// both become true in one update. Two handlers on one proxy would animate
    /// twice for one gesture.
    @Test("A drop lands and selects at once, and scrolls once")
    func oneGestureOneScroll() {
        let landed = card("dropped")
        let rows = drawn([landed])
        let before = ColumnFocus.of(landing: nil, selection: nil, drawn: rows)
        let after = ColumnFocus.of(
            landing: CardLanding(cardID: landed.id, stamp: UUID()),
            selection: landed.id, drawn: rows)

        let target = after.target(from: before)
        #expect(target == ColumnFocus.Target(cardID: landed.id, anchor: .center))
        // And nothing further: the same value again is not a second scroll.
        #expect(after.target(from: after) == nil)
    }

    /// `lastLanded` is never cleared, so a landing that kept outranking the
    /// selection would pin the column to the dropped card for ever — the bug a
    /// naive "landing first" ordering hides until the next keystroke.
    @Test("A landing stops winning once it is no longer the thing that changed")
    func aStaleLandingYields() {
        let landed = card("dropped")
        let next = card("next", order: 1)
        let rows = drawn([landed, next])
        let landing = CardLanding(cardID: landed.id, stamp: UUID())

        let afterDrop = ColumnFocus.of(landing: landing, selection: landed.id, drawn: rows)
        let afterArrow = ColumnFocus.of(landing: landing, selection: next.id, drawn: rows)

        #expect(
            afterArrow.target(from: afterDrop)
                == ColumnFocus.Target(cardID: next.id, anchor: nil))
    }

    /// `nil` is `ScrollViewProxy`'s "as little as possible". Centring on every
    /// press would drag the list under a reader who can already see the card.
    @Test("A selection step scrolls minimally; a landing centres")
    func anchors() {
        let one = card("one")
        let two = card("two", order: 1)
        let rows = drawn([one, two])

        let stepped = ColumnFocus.of(landing: nil, selection: two.id, drawn: rows)
            .target(from: ColumnFocus.of(landing: nil, selection: one.id, drawn: rows))
        #expect(stepped?.anchor == nil)

        let arrived = ColumnFocus.of(
            landing: CardLanding(cardID: one.id, stamp: UUID()), selection: one.id, drawn: rows
        ).target(from: ColumnFocus.of(landing: nil, selection: nil, drawn: rows))
        #expect(arrived?.anchor == .center)
    }

    @Test("The same card landing twice is two landings")
    func stampsSeparateTwoArrivals() {
        let card = card("walked")
        let rows = drawn([card])
        let first = ColumnFocus.of(
            landing: CardLanding(cardID: card.id, stamp: UUID()), selection: card.id, drawn: rows)
        let second = ColumnFocus.of(
            landing: CardLanding(cardID: card.id, stamp: UUID()), selection: card.id, drawn: rows)

        #expect(second.target(from: first)?.cardID == card.id)
    }

    /// The other half of #277. A `LazyVStack` never built a row for a card
    /// inside a folded group or past Done's horizon, so `scrollTo` would find
    /// nothing and do nothing — silently, which is this repository's most
    /// expensive failure shape.
    @Test("A column asks for nothing it is not drawing")
    func undrawnCardsAreNotFocused() {
        let hidden = card("hidden")
        let group = CardGroup(repoID: repoID, repoName: "Elliot", cards: [hidden])
        let folded = ColumnRows.build(
            .byRepository([group]), foldedRepoIDs: [repoID], foldedDays: [], selection: nil)

        let focus = ColumnFocus.of(
            landing: CardLanding(cardID: hidden.id, stamp: UUID()),
            selection: hidden.id, drawn: folded)

        #expect(focus == ColumnFocus())
        #expect(focus.target(from: ColumnFocus()) == nil)
    }

    /// A card selected in Backlog must not scroll To Do.
    @Test("A column ignores a selection that belongs to another column")
    func anotherColumnsSelection() {
        let mine = card("mine")
        let theirs = card("theirs")
        let rows = drawn([mine])

        let focus = ColumnFocus.of(landing: nil, selection: theirs.id, drawn: rows)
        #expect(focus.selected == nil)
        #expect(focus.target(from: ColumnFocus()) == nil)
    }
}
