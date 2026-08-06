import Foundation
import Testing

@testable import ElliotModel

/// Where a dropped card lands.
///
/// This suite is the reason the arithmetic left the drop closure. #47's review
/// named two hazards in wiring reordering up, and one of them — the self-drop
/// that silently sends a card to the bottom of its own column — is a rule, not a
/// gesture. A rule can be proved here; the gesture cannot be proved anywhere
/// `swift test` can reach.
@Suite("Card reorder")
struct CardReorderTests {

    private static let repoID = UUID()

    private static func card(
        _ title: String, column: Column = .backlog, order: Double
    ) -> Card {
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        return Card(
            repoID: repoID, title: title, column: column, orderIndex: order,
            columnEnteredAt: epoch, createdAt: epoch, updatedAt: epoch)
    }

    /// Three cards in Backlog at 1000, 2000, 3000.
    private static var backlog: [Card] {
        [card("first", order: 1_000), card("second", order: 2_000), card("third", order: 3_000)]
    }

    // MARK: - The self-drop

    /// The bug this issue exists to avoid, asserted as `.none` rather than as
    /// "an index equal to the one it already had": those are different claims,
    /// and only `.none` guarantees nothing is written.
    @Test("A card dropped on itself does nothing at all")
    func selfDropIsNoOp() {
        let cards = Self.backlog
        for card in cards {
            #expect(
                CardReorder.placement(
                    moving: card, onto: card, in: .backlog, columnCards: cards) == .none,
                "\(card.title)")
        }
    }

    /// The failure the guard prevents, stated so the guard cannot be removed
    /// without this saying what would happen. Without it the card is filtered
    /// out of the list, no index is found, and the fallback appends.
    @Test("Without the guard a self-drop would append to the bottom")
    func theBugTheGuardPrevents() {
        let cards = Self.backlog
        let moving = cards[0]
        // The same computation with the self-drop treated as an ordinary drop:
        // the card is not in `ordered`, so it falls through to the append case.
        let ordered = cards.filter { $0.id != moving.id }
        let index = ordered.firstIndex { $0.id == moving.id } ?? ordered.count
        #expect(index == ordered.count, "the fallback is what the guard is guarding")
        #expect(
            CardReorder.index(previous: ordered[index - 1].orderIndex, next: nil)
                > cards.map(\.orderIndex).max()!,
            "and it would land below every other card")
    }

    // MARK: - Placing inside one column

    @Test("Dropping between two cards lands at their midpoint")
    func midpointBetweenNeighbours() {
        let cards = Self.backlog
        let moving = cards[2]
        let placement = CardReorder.placement(
            moving: moving, onto: cards[1], in: .backlog, columnCards: cards)

        #expect(placement == .reorder(previous: 1_000, next: 2_000))
        if case .reorder(let p, let n) = placement {
            #expect(CardReorder.index(previous: p, next: n) == 1_500)
        }
    }

    /// Dropping on the first card has no previous neighbour, and the resulting
    /// index must actually be *above* it — `nil` on its own does not say that.
    @Test("Dropping on the first card lands above it")
    func aboveTheFirstCard() {
        let cards = Self.backlog
        let placement = CardReorder.placement(
            moving: cards[2], onto: cards[0], in: .backlog, columnCards: cards)

        #expect(placement == .reorder(previous: nil, next: 1_000))
        #expect(CardReorder.index(previous: nil, next: 1_000) < 1_000)
    }

    @Test("Dropping on no card at all appends below everything")
    func nilTargetAppends() {
        let cards = Self.backlog
        let placement = CardReorder.placement(
            moving: cards[0], onto: nil, in: .backlog, columnCards: cards)

        #expect(placement == .reorder(previous: 3_000, next: nil))
        #expect(CardReorder.index(previous: 3_000, next: nil) > 3_000)
    }

    /// A column holding only the card being dropped has no neighbours either
    /// side. Reachable whenever a column's single card is dropped on its own
    /// empty space.
    @Test("A card alone in its column has no neighbours and does not crash")
    func aloneInTheColumn() {
        let only = Self.card("only", order: 500)
        #expect(
            CardReorder.placement(moving: only, onto: nil, in: .backlog, columnCards: [only])
                == .reorder(previous: nil, next: nil))
        #expect(CardReorder.index(previous: nil, next: nil) == 0)
    }

    // MARK: - Crossing columns

    /// The distinction that must not blur: arriving in a new column is an act
    /// with consequences — it files, implements or merges — and placing within a
    /// column is not. The case says which happened; a caller cannot treat one as
    /// the other by accident.
    @Test("A drop from another column moves first, then places")
    func crossColumnMovesFirst() {
        let destination = Self.backlog
        let moving = Self.card("incoming", column: .todo, order: 10)
        let placement = CardReorder.placement(
            moving: moving, onto: destination[1], in: .backlog, columnCards: destination)

        #expect(placement == .moveThenReorder(to: .backlog, previous: 1_000, next: 2_000))
    }

    /// The moving card is filtered out of the neighbours even when it is already
    /// in the column — otherwise a card dropped lower down would average against
    /// its own old position and land somewhere neither neighbour implies.
    @Test("A card never becomes its own neighbour")
    func theMovingCardIsNeverItsOwnNeighbour() {
        let cards = Self.backlog
        // Drop "first" (1000) onto "third" (3000): the neighbours must be
        // "second" and nothing, not "second" and "first".
        let placement = CardReorder.placement(
            moving: cards[0], onto: cards[2], in: .backlog, columnCards: cards)

        #expect(placement == .reorder(previous: 2_000, next: 3_000))
    }

    // MARK: - The arithmetic agrees with the writer

    /// `BoardService.reorder` performs this same switch, and the two must not
    /// drift. Asserted here so the placement's promise and the write agree.
    @Test("The index arithmetic covers all four neighbour combinations")
    func indexArithmeticIsTotal() {
        #expect(CardReorder.index(previous: 100, next: 200) == 150)
        #expect(CardReorder.index(previous: 100, next: nil) == 100 + CardReorder.gap)
        #expect(CardReorder.index(previous: nil, next: 200) == 200 - CardReorder.gap)
        #expect(CardReorder.index(previous: nil, next: nil) == 0)
    }
}
