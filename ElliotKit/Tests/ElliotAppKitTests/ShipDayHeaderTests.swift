import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// The wording of a day header, which is the part of it a test can hold.
///
/// Where the header *sits* is layout, and `swift test` cannot see layout —
/// that is what Task 7's on-screen pass is for. What it can hold is that
/// "Today" is a word rather than a date, and that the sentence VoiceOver reads
/// says how many cards the day holds.
///
/// Both the calendar and the locale are supplied rather than taken from the
/// environment. A weekday name formatted in the ambient timezone is a
/// different weekday either side of midnight UTC, which would make this suite
/// pass in Brussels and fail in Auckland.
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private let en = Locale(identifier: "en_US")

/// 2023-11-14 22:13:20 UTC — a Tuesday, in UTC.
private let tuesday = Date(timeIntervalSince1970: 1_700_000_000)

@Suite("Ship day header")
struct ShipDayHeaderTests {

    @Test("Today and yesterday are words, not dates")
    func nearDaysAreWords() {
        #expect(ShipDayHeader.text(.today, calendar: utc, locale: en) == "Today")
        #expect(ShipDayHeader.text(.yesterday, calendar: utc, locale: en) == "Yesterday")
    }

    @Test("A day inside the week is its weekday name")
    func weekdayIsNamed() {
        #expect(ShipDayHeader.text(.weekday(tuesday), calendar: utc, locale: en) == "Tuesday")
    }

    @Test("An older day is an absolute date, and never empty")
    func olderDayIsADate() {
        let text = ShipDayHeader.text(.date(tuesday), calendar: utc, locale: en)
        #expect(text.contains("2023"))
        #expect(text.contains("14"))
        #expect(!text.isEmpty)
    }

    /// The header is formatted in the calendar the cards were bucketed in, so
    /// the word above a day and the day itself cannot disagree. Formatted in
    /// the ambient timezone instead, a card filed late on Tuesday UTC would sit
    /// under a header reading "Wednesday" for anyone east of it.
    @Test("The label is formatted in the calendar it was bucketed in")
    func honoursTheCalendarsTimeZone() {
        var kiritimati = Calendar(identifier: .gregorian)
        kiritimati.timeZone = TimeZone(identifier: "Pacific/Kiritimati")!  // UTC+14
        #expect(ShipDayHeader.text(.weekday(tuesday), calendar: utc, locale: en) == "Tuesday")
        #expect(ShipDayHeader.text(.weekday(tuesday), calendar: kiritimati, locale: en) == "Wednesday")
    }

    /// Same rule the column caption and the group header already follow: "1
    /// cards" is read aloud, and it is the kind of thing that makes a careful
    /// product look careless.
    @Test("A day's caption writes the singular out")
    func captionSingular() {
        #expect(BoardAccessibility.shipDayCaption(day: "Today", count: 1) == "Today, 1 card")
        #expect(BoardAccessibility.shipDayCaption(day: "Today", count: 3) == "Today, 3 cards")
        #expect(BoardAccessibility.shipDayCaption(day: "Tuesday", count: 0) == "Tuesday, 0 cards")
    }
}
