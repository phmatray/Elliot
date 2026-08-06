import Foundation
import Testing

@testable import ElliotModel

private let now = Date(timeIntervalSince1970: 1_700_000_000)

private func card(in column: Column, enteredDaysAgo days: Double) -> Card {
    Card(
        repoID: UUID(),
        title: "A card",
        column: column,
        columnEnteredAt: now.addingTimeInterval(-days * 86_400),
        createdAt: now,
        updatedAt: now
    )
}

@Suite("Card stagnation")
struct CardStagnationTests {

    @Test("A card younger than a day says nothing")
    func freshCardIsSilent() {
        #expect(card(in: .todo, enteredDaysAgo: 0).stagnation(now: now) == nil)
        #expect(card(in: .inProgress, enteredDaysAgo: 0.99).stagnation(now: now) == nil)
    }

    @Test("The waiting threshold opens at exactly one day")
    func waitingBoundary() {
        #expect(card(in: .todo, enteredDaysAgo: 1).stagnation(now: now) == .waiting(days: 1))
        #expect(card(in: .todo, enteredDaysAgo: 2.9).stagnation(now: now) == .waiting(days: 2))
    }

    @Test("The stalled threshold opens at exactly three days")
    func stalledBoundary() {
        #expect(card(in: .inReview, enteredDaysAgo: 2.99).stagnation(now: now) == .waiting(days: 2))
        #expect(card(in: .inReview, enteredDaysAgo: 3).stagnation(now: now) == .stalled(days: 3))
        #expect(card(in: .inReview, enteredDaysAgo: 40).stagnation(now: now) == .stalled(days: 40))
    }

    /// A backlog is *meant* to hold things for weeks, and a merged card is
    /// finished. Age only carries information for a card in transit.
    @Test("Backlog and Done never stagnate, however old", arguments: [Column.backlog, .done])
    func excludedColumns(column: Column) {
        #expect(card(in: column, enteredDaysAgo: 400).stagnation(now: now) == nil)
    }

    @Test("A card entered this very second is not stagnant")
    func sameSecond() {
        #expect(card(in: .inProgress, enteredDaysAgo: 0).stagnation(now: now) == nil)
    }

    /// A clock that has gone backwards must not read as a card from the future.
    @Test("A future timestamp is not stagnation")
    func futureTimestamp() {
        #expect(card(in: .todo, enteredDaysAgo: -5).stagnation(now: now) == nil)
    }

    @Test("The label is day-grained, because an age that ticks is a stopwatch")
    func shortLabel() {
        #expect(Stagnation.waiting(days: 2).shortLabel == "2d")
        #expect(Stagnation.stalled(days: 11).shortLabel == "11d")
        #expect(Stagnation.stalled(days: 11).days == 11)
    }

    @Test("Cancel stops being offered once a run is already winding down")
    func cancellability() {
        #expect(RunState.running.isCancellable)
        #expect(RunState.queued.isCancellable)
        #expect(RunState.stalled.isCancellable)
        #expect(!RunState.cancelling.isCancellable)
        #expect(!RunState.succeeded.isCancellable)
        #expect(!RunState.failed.isCancellable)
    }
}
