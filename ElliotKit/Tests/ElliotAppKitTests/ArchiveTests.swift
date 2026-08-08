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

    /// A repository change or a deletion invalidates the rows without changing
    /// the term — and `setSearch` is deliberately inert on an unchanged term,
    /// so it cannot be the thing that clears them.
    @Test("Clearing drops the rows and the total but keeps the term")
    func clearKeepsTheTerm() {
        var state = ArchiveState()
        state.setSearch("log")
        state.append([card("a"), card("b")], total: 44)
        state.clear()

        #expect(state.cards.isEmpty)
        #expect(state.loaded == 0)
        #expect(state.total == 0)
        #expect(!state.canLoadMore)
        #expect(state.search == "log")
    }

    /// `nil` from `archivePage` means "could not look" — the store is not open
    /// yet, or the read threw. An empty page means "there is nothing". The
    /// window says different things about the two, so they cannot be the same
    /// value.
    @MainActor
    @Test("A model with no store answers 'could not look', not 'nothing'")
    func noStoreIsNotAnEmptyArchive() async {
        let model = AppModel()
        let page = await model.archivePage(search: "", limit: 25, offset: 0)
        #expect(page == nil)
    }

    // MARK: - A day the page boundary cut (#162)

    /// A day holding more cards than one page, plus older days behind it —
    /// exactly the seeded shape the on-screen pass used: 30 cards on the newest
    /// day, 36 more below.
    private func dayOf(_ count: Int, daysAgo: Int, calendar: Calendar) -> [Card] {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: epoch)!
        return (0..<count).map { i in
            Card(
                repoID: UUID(), title: "Ordinary finished card \(i)", column: .done,
                columnEnteredAt: day.addingTimeInterval(Double(i) * 60),
                createdAt: epoch, updatedAt: epoch
            )
        }
    }

    /// The defect this issue's second half is about, as arithmetic.
    ///
    /// The first page holds 25 of a day that has 30, so the header's own row
    /// count is 25 — five short, and indistinguishable on screen from a day
    /// that genuinely held 25. `partialDay` is what lets the header say so.
    @Test("A day cut by the page boundary is named, and its row count is short")
    func pageBoundaryCutsTheOldestLoadedDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let newest = dayOf(30, daysAgo: 3, calendar: calendar)
        let older = dayOf(9, daysAgo: 5, calendar: calendar)
        let all = (newest + older).sorted { $0.columnEnteredAt > $1.columnEnteredAt }

        // What `doneCards(limit:offset:)` hands back for page one.
        let page = Array(all.prefix(ArchiveState.pageSize))
        var state = ArchiveState()
        state.append(page, total: all.count)

        let log = shippingLog(state.cards, now: epoch, calendar: calendar, horizonDays: nil)
        #expect(log.days.count == 1)
        // Short of the 30 that day actually holds — the number that used to be
        // drawn as if it were the day's.
        #expect(log.days[0].cards.count == 25)
        #expect(state.canLoadMore)
        #expect(log.partialDay(moreToLoad: state.canLoadMore) == log.days[0].start)
    }

    /// The complement, and the reason this is not simply "never show a count in
    /// the archive": once the last page is in, every day is whole again.
    @Test("With the last page loaded, no day is marked as cut")
    func fullyLoadedArchiveMarksNothingPartial() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let all = dayOf(30, daysAgo: 3, calendar: calendar) + dayOf(9, daysAgo: 5, calendar: calendar)
        var state = ArchiveState()
        state.append(all, total: all.count)

        let log = shippingLog(state.cards, now: epoch, calendar: calendar, horizonDays: nil)
        #expect(!state.canLoadMore)
        #expect(log.partialDay(moreToLoad: state.canLoadMore) == nil)
        #expect(log.days.map(\.cards.count) == [30, 9])
    }
}
