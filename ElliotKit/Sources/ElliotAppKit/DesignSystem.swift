import ElliotModel
import SwiftUI

/// The board's visual vocabulary, in one place.
///
/// Two rules carry the whole system, and both encode something the app already
/// believes rather than decorating it:
///
/// 1. **Monospace means a machine established it.** Issue numbers, PR numbers,
///    branch names, costs, elapsed times — anything read back from `gh` or
///    `git` — is set in `Type.fact`. Everything a human typed stays
///    proportional. The app judges a run by `verifiedOutcome` and never by the
///    agent's prose; the type says which of the two you are looking at.
///
/// 2. **Colour is reserved for consequence.** `armed` marks a gesture that will
///    start an agent, `irreversible` one that will merge to a default branch on
///    github.com. Neither is used for anything else, so neither can be read as
///    decoration.
enum Palette {
    /// A gesture here starts an autonomous run. Deliberately not the system
    /// accent — that is user-configurable, and a meaning that changes with a
    /// preference pane is not a meaning.
    static let armed = dynamic(BrandColor.armed)

    /// Reserved for the one move that cannot be taken back: merging the pull
    /// request. Used by exactly one column and one confirm button, so its
    /// scarcity is what makes it legible.
    static let irreversible = dynamic(BrandColor.irreversible)

    /// `gh` confirmed it. Not `.green`, which is also the system's tint for
    /// half a dozen unrelated affordances.
    static let verified = dynamic(BrandColor.verified)

    /// A move was refused, or a run failed. Split from `attention` on purpose:
    /// the board previously used one orange for refusals, warnings, stalls and
    /// tool denials, which left it meaning only "something is off".
    static let refused = dynamic(BrandColor.refused)

    /// Still alive, but wants a decision — stalled, or finished having been
    /// refused a tool.
    static let attention = dynamic(BrandColor.attention)

    /// Nothing happens on arrival. The absence of a signal is itself the
    /// signal.
    static let inert = Color.secondary

    /// The third type tier, and **not** a sixth accent — it is greyscale, so it
    /// spends none of the colour budget the two rules above depend on.
    ///
    /// It exists because the tier it names did not render. Eleven call sites
    /// wrote `.foregroundStyle(.tertiary)` *around* a `Fact`, and `Fact` sets
    /// `foregroundStyle` on its own `Text`; SwiftUI resolves innermost-first, so
    /// every one of them was silently discarded and drew at `secondary`. A tier
    /// reachable only through the initialiser cannot be missed that way.
    static let quiet = Color(nsColor: .tertiaryLabelColor)

    /// The cards in the mark. Not a consequence colour and never used as one —
    /// it is the mark's own paper, and it is the same in both appearances
    /// because a macOS 15 app icon does not follow the system appearance.
    static let paper = dynamic(BrandColor.paper)

    static func dynamic(_ brand: BrandColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: isDark ? brand.dark : brand.light)
        })
    }
}

private extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(
            srgbRed: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Fills, not consequences.
///
/// `Palette` means *something happens*; these mean *this is a surface*. They
/// live apart so the five accents keep their scarcity, and they are named at
/// all because fifteen hand-written `Color.secondary.opacity(…)` values across
/// nine files encoded only two ideas between them — a recessed panel and a
/// chip — at nine different strengths nobody chose deliberately.
enum Surface {
    /// A panel set into the page: run rows, proposal rows, repo sections.
    static let recess = Color.secondary.opacity(0.06)
    /// Fainter, and only where the surface itself is refused.
    static let recessFaint = Color.secondary.opacity(0.03)
    static let chipFill = Color.secondary.opacity(0.12)
    static let chipFillHover = Color.secondary.opacity(0.22)

    /// A consequence colour used as a *background*. Kept as a function so the
    /// tint stays the argument: a wash is always about something.
    static func wash(_ tint: Color) -> Color { tint.opacity(0.12) }
    static func washBorder(_ tint: Color) -> Color { tint.opacity(0.45) }
}

enum Type {
    /// Column headers and field labels: small, spaced, unmistakably a console
    /// label rather than content.
    static let label = Font.system(size: 11, weight: .semibold).width(.standard)
    /// What a card is about — a human wrote it.
    static let cardTitle = Font.system(size: 13, weight: .medium)
    /// A card title one step down: the name of a row inside a panel.
    static let rowTitle = Font.system(size: 12, weight: .medium)
    /// The story, and other prose read at a glance.
    static let prose = Font.system(size: 11)
    /// Prose given room — the inspector reads a story a point larger than the
    /// card glances at it. Not named `body`, which is `Font.body` already.
    static let bodyProse = Font.system(size: 12)
    /// Anything `gh`, `git` or the process itself established. Monospaced
    /// digits so a column of costs or elapsed times lines up.
    static let fact = Font.system(size: 11, design: .monospaced)
    static let factSmall = Font.system(size: 10, design: .monospaced)
    /// Log output.
    static let log = Font.system(size: 11, design: .monospaced)
    static let sheetTitle = Font.system(size: 17, weight: .semibold)
}

enum Metric {
    /// Below this the five columns start scrolling instead of shrinking
    /// further — a card title needs about this much to stay readable.
    static let minColumnWidth: CGFloat = 226
    /// Wide enough for a branch name set in the fact face without wrapping,
    /// and narrow enough that all five columns still fit beside it.
    static let inspectorWidth: CGFloat = 344
    /// The radius ladder: `nested < card < panel < column`. A rounded thing
    /// inside another rounded thing reads wrong at the same radius, and the two
    /// values added here were both already in use as literals — this names
    /// them, it does not introduce them.
    static let nestedRadius: CGFloat = 5
    static let cardRadius: CGFloat = 7
    static let panelRadius: CGFloat = 8
    static let columnRadius: CGFloat = 10
    static let railHeight: CGFloat = 2
    static let gutter: CGFloat = 10
    /// `ColumnView`'s own horizontal list padding. Named because the detail
    /// panel's tether has to cross it to touch the card — `PanelLayout
    /// .tetherReach` is `gutter + columnListPadding`, and left as a bare 8 in
    /// one file and an 18 in another the tether stops touching the day either
    /// moves. This names the literal, it does not introduce it.
    static let columnListPadding: CGFloat = 8
    /// The detail panel floats above the columns it is placed between, so it
    /// carries the only shadow on the board. Read off the approved mockup's
    /// dominant layer (`0 12px 28px rgba(0,0,0,.10)`), halving the CSS blur for
    /// SwiftUI's radius.
    static let panelElevation: (radius: CGFloat, y: CGFloat, opacity: Double)
        = (radius: 14, y: 12, opacity: 0.10)
}

enum Elapsed {
    /// How long a run has been going, in the fact face's idiom. Shared by the
    /// card strip and the analysis lens strip so a run reads the same wherever
    /// it is watched.
    /// The hours branch is not decoration: there is deliberately no wall-clock
    /// kill, because `merge-pr` waiting on CI for hours is legitimate. Without
    /// it a four-hour merge reads `"247m 03s"`.
    static func short(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m \(pad(seconds % 60))s" }
        return "\(seconds / 3_600)h \(pad((seconds % 3_600) / 60))m"
    }

    /// How long ago something happened. An **age**, not a stopwatch — one
    /// coarsening unit, because "finished 3h ago" is the whole message and
    /// "3h 07m 12s ago" is the same message plus noise.
    static func age(of then: Date, at now: Date = .now) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(then)))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3_600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3_600)h ago" }
        return "\(seconds / 86_400)d ago"
    }

    private static func pad(_ value: Int) -> String { String(format: "%02d", value) }
}

/// The uppercase, letter-spaced console label used for column names and field
/// captions.
///
/// Set the tier with `tint:`. A `.foregroundStyle` applied to a `ConsoleLabel`
/// from outside is overridden by the one on its own `Text` and does nothing.
struct ConsoleLabel: View {
    var text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text.uppercased())
            .font(Type.label)
            .tracking(0.7)
            .foregroundStyle(tint)
    }
}

/// A value that came from somewhere other than this app — an issue number, a
/// branch, a cost. Set in the fact face so it reads as quoted, not authored.
///
/// Set the tier with `tint:` — `Palette.quiet` for the third tier. A
/// `.foregroundStyle` applied to a `Fact` from outside is overridden by the one
/// on its own `Text` and does nothing; eleven call sites learned that the hard
/// way.
struct Fact: View {
    var text: String
    var tint: Color = .secondary
    var small = false

    var body: some View {
        Text(text)
            .font(small ? Type.factSmall : Type.fact)
            .foregroundStyle(tint)
    }
}
