import ElliotModel
import SwiftUI

/// One day's heading in the Done column and in the archive.
///
/// Deliberately the same shape as `BoardView.groupHeader(_:)` — chevron,
/// `ConsoleLabel`, a small count, and the whole row a plain button. A day and a
/// repository are both "a run of cards under a heading you can fold away", and
/// drawing them differently would suggest they are different kinds of thing.
struct ShipDayHeader: View {
    var label: ShipDayLabel
    var count: Int
    /// Whether `count` is a floor rather than the day's total — true only in the
    /// archive, and only for the one day a page boundary may have cut
    /// (`ShippingLog.partialDay(moreToLoad:)`, which is where that is decided).
    ///
    /// Defaulted so the board's Done column, which is not paged and whose counts
    /// are therefore always whole, keeps saying exactly what it said before.
    var partial: Bool = false
    var collapsed: Bool
    var onToggle: () -> Void

    /// Taken from the environment here, and injected in `text(_:calendar:locale:)`
    /// below — a view may read the ambient calendar, a rule may not.
    private var calendar: Calendar { .current }
    private var locale: Locale { .current }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 5) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                ConsoleLabel(text: Self.text(label, calendar: calendar, locale: locale))
                Fact(text: Self.countText(count: count, partial: partial), tint: Palette.quiet, small: true)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.top, 4)
        }
        .buttonStyle(.plain)
        // Written out by the same function the column caption uses, for the
        // reason recorded there: the group header spelled "1 card" by hand and
        // the caption above it did not, so two labels on one column disagreed.
        .accessibilityLabel(
            BoardAccessibility.shipDayCaption(
                day: Self.text(label, calendar: calendar, locale: locale),
                count: count,
                partial: partial
            )
        )
    }

    /// How the count capsule reads.
    ///
    /// "23+" and not "23" when a page boundary may have cut this day. The bare
    /// number reads as a claim about the day — it sits next to the day's name —
    /// and in the archive it counts the rows loaded so far, which is a different
    /// thing whenever there are more to load.
    ///
    /// A function rather than an expression in the `body` for the same reason
    /// `text(_:calendar:locale:)` is one: a string assembled inline is a claim
    /// no test can read, and this is the whole of what the reader sees.
    static func countText(count: Int, partial: Bool) -> String {
        partial ? "\(count)+" : "\(count)"
    }

    /// How a day reads.
    ///
    /// Both the calendar and the locale are parameters rather than
    /// `.current`, which is what makes this assertable: a weekday name
    /// formatted in the ambient timezone is a *different weekday* either side
    /// of midnight, so a test of it would pass in one timezone and fail in
    /// another.
    ///
    /// The timezone comes from the calendar rather than being a third
    /// parameter, because the calendar is the one that bucketed these cards —
    /// `ShipDay.start` is a `startOfDay` in it. Formatting in any other
    /// timezone could print a weekday the bucket does not agree with.
    static func text(_ label: ShipDayLabel, calendar: Calendar, locale: Locale) -> String {
        switch label {
        // Plain literals, like every other string in this app. There is no
        // localisation table here, and `Bundle.module` does not exist for a
        // target that declares no resources.
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .weekday(let day):
            day.formatted(
                Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                    .weekday(.wide)
            )
        case .date(let day):
            day.formatted(
                Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                    .day().month(.abbreviated).year()
            )
        }
    }
}
