import Foundation

/// How a day header should read.
///
/// A case, not a string: `Today` and a weekday name are locale-dependent, and
/// `ElliotModel` is dependency-free on purpose — it holds no `DateFormatter`
/// and no `Locale`. Which bucket a day falls in is a *rule*, so it is decided
/// here; how that bucket is worded is the view's business.
public enum ShipDayLabel: Sendable, Equatable, Hashable {
    case today
    case yesterday
    /// Within the last week: drawn as a weekday name.
    case weekday(Date)
    /// Older than that: drawn as an absolute date. Reachable on the board only
    /// through the never-empty guard below, and routinely in the archive.
    case date(Date)
}

/// One calendar day's finished cards, newest card first.
public struct ShipDay: Sendable, Equatable, Hashable, Identifiable {
    public var id: Date { start }

    /// Start of day in the caller's calendar — the bucket key, and the value a
    /// view keys collapse state on.
    public var start: Date
    public var label: ShipDayLabel
    public var cards: [Card]

    public init(start: Date, label: ShipDayLabel, cards: [Card]) {
        self.start = start
        self.label = label
        self.cards = cards
    }
}

/// What Done draws, and what it left out.
public struct ShippingLog: Sendable, Equatable {
    /// A week. Long enough to hold a normal working rhythm, short enough that
    /// the column stops being a pile. A constant rather than a preference:
    /// the whole point of deciding this at read time is that changing it is a
    /// one-line change, not a migration.
    public static let defaultHorizonDays = 7

    public var days: [ShipDay]

    /// Finished cards the horizon excluded. `0` when nothing is hidden, which
    /// is what tells a view whether to draw the archive footer at all.
    public var olderCount: Int

    /// Every finished card, drawn or not.
    ///
    /// The column caption reports *this*, never `days.flatMap(\.cards).count`.
    /// A board that said "Done, 8 cards" while forty-four existed would be
    /// under-reporting itself to the one reader who cannot scroll to check.
    public var totalCount: Int

    public init(days: [ShipDay] = [], olderCount: Int = 0, totalCount: Int = 0) {
        self.days = days
        self.olderCount = olderCount
        self.totalCount = totalCount
    }
}

/// Groups finished cards by the day they landed.
///
/// Pure: no clock, no locale, no I/O. The caller supplies `now` and the
/// `Calendar`, which is what makes the rule testable at a fixed instant in a
/// fixed timezone rather than intermittently near midnight.
///
/// The cards are taken as given — this does not filter by column. `Done` is
/// the only column whose age means anything (`Card.stagnation(now:)` says so
/// from the other side), and the caller has already selected it.
///
/// - Parameters:
///   - horizonDays: How many days back the board draws. `nil` means no horizon
///     at all: every day is returned and `olderCount` is `0`. That is what the
///     archive passes, and it is why this is one function rather than two.
///
/// Two guards are load-bearing and neither is obvious:
///
/// - **The newest day is always drawn**, even when the horizon excludes every
///   card. Come back after a fortnight away and a strict horizon would render
///   an empty column beneath a footer reading "44 older" — strictly correct,
///   and a worse answer than the pile it replaced.
/// - **A day cannot be in the future.** `columnEnteredAt` is written by
///   whichever machine moved the card, so clock skew is possible; a skewed card
///   is folded into today rather than opening a second day above it, which
///   would draw two "Today" headers.
public func shippingLog(
    _ cards: [Card],
    now: Date,
    calendar: Calendar,
    horizonDays: Int? = ShippingLog.defaultHorizonDays
) -> ShippingLog {
    guard !cards.isEmpty else { return ShippingLog() }

    let today = calendar.startOfDay(for: now)

    var byDay: [Date: [Card]] = [:]
    for card in cards {
        let day = min(calendar.startOfDay(for: card.columnEnteredAt), today)
        byDay[day, default: []].append(card)
    }

    /// Whole days between a bucket and today. Never negative, by the clamp above.
    func daysBack(_ day: Date) -> Int {
        calendar.dateComponents([.day], from: day, to: today).day ?? 0
    }

    func label(for day: Date) -> ShipDayLabel {
        switch daysBack(day) {
        case ...0: .today
        case 1: .yesterday
        case 2...6: .weekday(day)
        default: .date(day)
        }
    }

    let allDays = byDay.keys.sorted(by: >)

    var drawn = allDays
    var olderCount = 0
    if let horizonDays {
        drawn = allDays.filter { daysBack($0) <= horizonDays }
        if drawn.isEmpty, let newest = allDays.first { drawn = [newest] }
        let drawnDays = Set(drawn)
        olderCount = allDays
            .filter { !drawnDays.contains($0) }
            .reduce(0) { $0 + (byDay[$1]?.count ?? 0) }
    }

    let days = drawn.map { day in
        ShipDay(
            start: day,
            label: label(for: day),
            // Newest first, then by id so no two cards can tie — the same
            // reason `cardQuery` ends on `id`. Two calls against an unchanged
            // board must not disagree about what they drew.
            cards: (byDay[day] ?? []).sorted {
                $0.columnEnteredAt == $1.columnEnteredAt
                    ? $0.id.uuidString < $1.id.uuidString
                    : $0.columnEnteredAt > $1.columnEnteredAt
            }
        )
    }

    return ShippingLog(days: days, olderCount: olderCount, totalCount: cards.count)
}
