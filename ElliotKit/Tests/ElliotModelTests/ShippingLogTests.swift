import Foundation
import Testing

@testable import ElliotModel

/// Fixed on purpose. A rule tested against `Date()` fails somewhere near
/// midnight, and one tested against `Calendar.current` fails in another
/// timezone — both intermittently, on someone else's machine.
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// 2023-11-14 22:13:20 UTC, a Tuesday.
private let now = Date(timeIntervalSince1970: 1_700_000_000)

private func done(_ daysAgo: Double, id: UUID = UUID()) -> Card {
    let at = now.addingTimeInterval(-daysAgo * 86_400)
    return Card(
        id: id,
        repoID: UUID(),
        title: "A finished card",
        column: .done,
        columnEnteredAt: at,
        createdAt: at,
        updatedAt: at
    )
}

@Suite("Shipping log")
struct ShippingLogTests {

    @Test("Today, yesterday and a weekday each get their own bucket, newest first")
    func buckets() {
        let log = shippingLog([done(0.1), done(1.1), done(3.1)], now: now, calendar: utc, horizonDays: 7)
        #expect(log.days.count == 3)
        #expect(log.days[0].label == .today)
        #expect(log.days[1].label == .yesterday)
        if case .weekday = log.days[2].label {} else {
            Issue.record("expected .weekday, got \(log.days[2].label)")
        }
        #expect(log.olderCount == 0)
        #expect(log.totalCount == 3)
    }

    @Test("Days come back newest first, whatever order the cards arrived in")
    func daysDescend() {
        let log = shippingLog([done(3.1), done(0.1), done(1.1)], now: now, calendar: utc, horizonDays: 7)
        #expect(log.days.map(\.start) == log.days.map(\.start).sorted(by: >))
    }

    @Test("Cards beyond the horizon are counted, not drawn")
    func horizonHides() {
        let log = shippingLog([done(0.1), done(30), done(60)], now: now, calendar: utc, horizonDays: 7)
        #expect(log.days.count == 1)
        #expect(log.olderCount == 2)
        // The caption reports this, so the board cannot under-report itself.
        #expect(log.totalCount == 3)
    }

    @Test("A day exactly on the horizon is kept; one past it is not")
    func horizonBoundary() {
        let log = shippingLog([done(7), done(8)], now: now, calendar: utc, horizonDays: 7)
        #expect(log.days.count == 1)
        #expect(log.olderCount == 1)
    }

    @Test("The newest day is drawn even when the horizon excludes everything")
    func neverEmptyWhileCardsExist() {
        // A column showing nothing under a footer reading "3 older" would be a
        // worse answer than the pile this feature replaces.
        let log = shippingLog([done(30), done(31), done(60)], now: now, calendar: utc, horizonDays: 7)
        #expect(log.days.count == 1)
        #expect(log.days[0].cards.count == 1)
        #expect(log.olderCount == 2)
        #expect(log.totalCount == 3)
    }

    @Test("A nil horizon draws every day and hides nothing — what the archive asks for")
    func noHorizon() {
        let log = shippingLog([done(0.1), done(30), done(60)], now: now, calendar: utc, horizonDays: nil)
        #expect(log.days.count == 3)
        #expect(log.olderCount == 0)
        #expect(log.totalCount == 3)
    }

    @Test("A zero horizon keeps today alone")
    func zeroHorizon() {
        let log = shippingLog([done(0.1), done(1.1)], now: now, calendar: utc, horizonDays: 0)
        #expect(log.days.count == 1)
        #expect(log.days[0].label == .today)
        #expect(log.olderCount == 1)
    }

    @Test("No cards is an empty log, not a crash")
    func empty() {
        let log = shippingLog([], now: now, calendar: utc, horizonDays: 7)
        #expect(log.days.isEmpty)
        #expect(log.olderCount == 0)
        #expect(log.totalCount == 0)
    }

    @Test("Within a day, cards are newest first")
    func withinDay() {
        let older = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let newer = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        let log = shippingLog(
            [done(0.5, id: older), done(0.1, id: newer)], now: now, calendar: utc, horizonDays: 7
        )
        #expect(log.days[0].cards.map(\.id) == [newer, older])
    }

    @Test("Two cards landing in the same instant still come back in a fixed order")
    func tiesAreDeterministic() {
        // Same reason `cardQuery` ends on `id`: two calls against an unchanged
        // board must not disagree about what they drew.
        let a = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        let one = shippingLog([done(0.2, id: a), done(0.2, id: b)], now: now, calendar: utc)
        let two = shippingLog([done(0.2, id: b), done(0.2, id: a)], now: now, calendar: utc)
        #expect(one.days[0].cards.map(\.id) == two.days[0].cards.map(\.id))
    }

    @Test("A clock that has run ahead does not open a day in the future")
    func futureTimestampLandsInToday() {
        // `columnEnteredAt` comes from whichever machine moved the card. Skew
        // must not produce a "Today" header above a second "Today" header.
        let log = shippingLog([done(-5), done(0.1)], now: now, calendar: utc, horizonDays: 7)
        #expect(log.days.count == 1)
        #expect(log.days[0].label == .today)
        #expect(log.days[0].cards.count == 2)
    }

    @Test("Every card is accounted for, drawn or counted")
    func nothingIsLost() {
        let cards = [done(0.1), done(1.1), done(30), done(60), done(90)]
        let log = shippingLog(cards, now: now, calendar: utc, horizonDays: 7)
        #expect(log.days.flatMap(\.cards).count + log.olderCount == cards.count)
        #expect(log.totalCount == cards.count)
    }

    // MARK: - Which day a page boundary can understate

    @Test("With everything loaded, no day's count is a guess")
    func nothingIsPartialWhenFullyLoaded() {
        let log = shippingLog([done(0.1), done(1.1), done(3.1)], now: now, calendar: utc, horizonDays: nil)
        #expect(log.partialDay(moreToLoad: false) == nil)
    }

    /// Written against the corpus rather than against the implementation: the
    /// named day is asserted to be *the one the page left short*, which is a
    /// claim about the data. `== days.last?.start` was the first version of this
    /// and it restated the function body, so it could not have failed for any
    /// implementation of that shape — including a wrong one.
    @Test("While more can load, the named day is the one the page left short")
    func partialDayIsTheDayThePageCut() {
        // Two whole days and a third, in the order `doneCards` returns them.
        let corpus = ([done(0.1), done(0.2)] + [done(1.1), done(1.2), done(1.3)] + [done(2.1)])
            .sorted { $0.columnEnteredAt > $1.columnEnteredAt }
        let whole = shippingLog(corpus, now: now, calendar: utc, horizonDays: nil)

        // A page that stops partway through the second day.
        let page = shippingLog(Array(corpus.prefix(4)), now: now, calendar: utc, horizonDays: nil)
        let named = page.partialDay(moreToLoad: true)

        var short: [Date] = []
        for day in page.days {
            let trueCount = whole.days.first { $0.start == day.start }?.cards.count
            if day.cards.count < (trueCount ?? 0) { short.append(day.start) }
        }
        #expect(short.count == 1)
        #expect(named == short.first)
    }

    /// ⛔ A horizon-limited log cannot name a cut day, and must not guess one.
    ///
    /// `days.last` there is the oldest day *inside* the horizon — provably
    /// whole — while the cards whose count is genuinely unknown are the ones
    /// folded into `olderCount` and absent from `days` entirely. The board's own
    /// `doneLog()` is exactly such a log, so nothing but this guard stops a
    /// caller being handed a confidently wrong day.
    @Test("A horizon-limited log answers 'I cannot say' rather than naming a whole day")
    func horizonLimitedLogNamesNothing() {
        let log = shippingLog([done(0.1), done(1.1), done(30), done(60)], now: now, calendar: utc, horizonDays: 7)
        #expect(log.olderCount == 2)
        #expect(log.partialDay(moreToLoad: true) == nil)
    }

    @Test("An empty log has no partial day to name")
    func emptyLogHasNoPartialDay() {
        #expect(ShippingLog().partialDay(moreToLoad: true) == nil)
    }
}
