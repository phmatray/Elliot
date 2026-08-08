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

    /// The start of the one day whose card count a page boundary can
    /// understate, or `nil` when every count here is exact.
    ///
    /// Only the archive can produce a partial day, because only the archive
    /// pages. It reads in `columnEnteredAt DESC, id DESC` — the order
    /// `BoardStore.doneCards` imposes and the one this function's tie-break
    /// deliberately matches — and re-buckets each page as it arrives. A cut can
    /// therefore only ever fall at the **end** of what has been loaded, so every
    /// day above the last is whole and exactly one may be short.
    ///
    /// A rule and not a view's arithmetic: which day is trustworthy is a claim
    /// about the data, and `ShipDayHeader` renders whatever it is handed.
    ///
    /// ⚠️ It answers "may be short", never "is short". A page that happens to
    /// end exactly on a day boundary leaves a whole day marked as partial, which
    /// understates what is known and is the safe direction — the failure this
    /// exists to prevent is a header stating a number it cannot support. Being
    /// exact instead means a per-day `GROUP BY` in SQL, and that is not the
    /// cheap fix it looks: these buckets are `calendar.startOfDay` in the
    /// *reader's* calendar, which SQLite cannot reproduce for an arbitrary
    /// timezone. A count that disagreed with the header it sits on would be a
    /// worse defect than a `+`.
    ///
    /// ⛔ **`olderCount == 0` is load-bearing, not defensive.** Under a horizon
    /// `days.last` is the oldest day *inside* it — provably whole — while the
    /// cards whose count is genuinely unknown are folded into `olderCount` and
    /// are not in `days` at all. The board's `doneLog()` is exactly such a log,
    /// so without this a caller would be handed a confidently wrong day. The
    /// value therefore checks itself rather than trusting a precondition its
    /// signature cannot express.
    public func partialDay(moreToLoad: Bool) -> Date? {
        guard moreToLoad, olderCount == 0 else { return nil }
        return days.last?.start
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
            //
            // The tie-break descends, matching `doneCards`' `id DESC`. Neither
            // direction means anything on its own, but they have to agree: the
            // archive pages in SQL order and re-sorts each page with this
            // function, so an ascending tie-break here would make a page of
            // same-second cards a middle slice of its day rather than a prefix,
            // and later pages would insert rows *above* ones already on screen.
            cards: (byDay[day] ?? []).sorted {
                $0.columnEnteredAt == $1.columnEnteredAt
                    ? $0.id.uuidString > $1.id.uuidString
                    : $0.columnEnteredAt > $1.columnEnteredAt
            }
        )
    }

    return ShippingLog(days: days, olderCount: olderCount, totalCount: cards.count)
}
