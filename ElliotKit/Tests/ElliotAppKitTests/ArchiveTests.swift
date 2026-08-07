import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// The archive's paging arithmetic, which is a decision rather than a layout.
///
/// Where the rows sit is Task 7's problem. What a test can hold is that the
/// window knows when to stop asking for more, and that changing the search term
/// cannot leave page two of the previous query on screen.
@Suite("Archive")
struct ArchiveTests {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func card(_ title: String) -> Card {
        Card(
            repoID: UUID(), title: title, column: .done,
            columnEnteredAt: epoch, createdAt: epoch, updatedAt: epoch
        )
    }

    @Test("More remains only while fewer rows are loaded than exist")
    func canLoadMore() {
        var state = ArchiveState()
        state.append([card("a"), card("b")], total: 44)
        #expect(state.canLoadMore)

        state.append(Array(repeating: card("x"), count: 42), total: 44)
        #expect(!state.canLoadMore)
    }

    @Test("An empty archive never offers to load more")
    func emptyOffersNothing() {
        var state = ArchiveState()
        #expect(!state.canLoadMore)
        state.append([], total: 0)
        #expect(!state.canLoadMore)
    }

    /// The offset for the next page is the number of rows already held. Taken
    /// from `cards.count` rather than accumulated, so a page that arrives twice
    /// — a re-entrant load, a view that reappears — cannot walk the offset past
    /// rows nobody has seen.
    @Test("Loaded tracks the rows actually held")
    func loadedTracksRows() {
        var state = ArchiveState()
        state.append([card("a"), card("b")], total: 10)
        #expect(state.loaded == 2)
        state.append([card("c")], total: 10)
        #expect(state.loaded == 3)
        #expect(state.cards.map(\.title) == ["a", "b", "c"])
    }

    @Test("Changing the search resets paging, so page 2 of the old query cannot leak in")
    func searchResets() {
        var state = ArchiveState()
        state.append([card("a"), card("b")], total: 44)
        state.setSearch("log")

        #expect(state.search == "log")
        #expect(state.loaded == 0)
        #expect(state.cards.isEmpty)
        // Reset too: a stale total would offer a "Load more" against a filter
        // that no longer applies.
        #expect(state.total == 0)
        #expect(!state.canLoadMore)
    }

    /// Re-running the same term must not clear what is on screen — `.task(id:)`
    /// fires on appearance as well as on change, and a reset there would blank
    /// the window every time it regained focus.
    @Test("Setting the same search again changes nothing")
    func sameSearchIsInert() {
        var state = ArchiveState()
        state.append([card("a")], total: 44)
        state.setSearch("")
        #expect(state.loaded == 1)
        #expect(state.total == 44)
    }
}
