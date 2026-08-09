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
///
///    There is exactly **one** exception, and it is written down here rather
///    than left for someone to discover: syntax colour inside a fenced code
///    block spends `armed` on keywords and `verified` on strings, because the
///    approved mockup does. It is bounded by the fence's own `Surface.well`
///    ground, it never reaches an inline code span or a word of prose, and it
///    adds no sixth accent. `CodeTokenKind.tint` in `MarkdownBlocks.swift`
///    carries the full reasoning and what the trade costs. A second exception
///    should be argued at least as hard as that one was.
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

    /// The same wash, demoted: the surface is about something that is *not*
    /// going to happen — a refused next step, a pane that cannot act yet.
    ///
    /// It exists because the strength was written by hand. `InspectorView` drew
    /// the refused next step as `wash(tint).opacity(0.6)`, and the detail panel
    /// needs the same ground in several more places; a second hand-written
    /// multiplier at each of them is exactly how the fifteen unchosen
    /// `Color.secondary.opacity(…)` values this enum replaced came about.
    ///
    /// 0.09, not the 0.072 that multiplier produced: the demotion has to stay
    /// visible as a *surface* against `recess`, and below about 0.08 a tinted
    /// wash stops being distinguishable from the untinted recess behind it.
    static func washFaint(_ tint: Color) -> Color { tint.opacity(0.09) }

    static func washBorder(_ tint: Color) -> Color { tint.opacity(0.45) }

    /// The 1pt rule *inside* a panel: between two verdict rows, above a plan
    /// item, under a table cell.
    ///
    /// Greyscale, so it spends none of the colour budget, and derived from
    /// `.primary` so it inverts with the appearance the way the mockup's
    /// `--hair` does (`rgba(0,0,0,.10)` light, `rgba(255,255,255,.10)` dark).
    /// Deliberately weaker than `NSColor.separatorColor`, which divides one
    /// component from another; this divides rows of the same thing, and a rule
    /// that separates a thing from itself should be barely there.
    static let hairline = Color.primary.opacity(0.10)

    /// The ground under machine output: code fences in an issue body, the run
    /// log, a tool result's preview. The visual counterpart of `Type.fact` —
    /// where the fact face says *a machine established this*, the well says
    /// *this whole region is a machine's output*.
    ///
    /// Hard-coded rather than reusing `NSColor.textBackgroundColor`, because a
    /// well has to read as **set into** the panel, which in a dark appearance
    /// means darker than the window behind it. Measured on macOS 15: in
    /// `.darkAqua`, `.textBackgroundColor` and `.windowBackgroundColor` are the
    /// same `#1E1E1E`, so a well drawn with it is not a well — it is invisible.
    /// These are the mockup's `--code`, which is darker than its `--window` in
    /// both appearances.
    ///
    /// The `BrandColor` here is a light/dark pair, **not** a sixth brand
    /// colour: `BrandColor` is the shape of such a pair, and `Palette.dynamic`
    /// is the one place in the app that resolves one against the appearance.
    /// Minting a named constant for it would put a fill in the list that
    /// `BrandColor.consequences` exists to keep down to five.
    static let well = Palette.dynamic(BrandColor(light: 0xF5_F5F7, dark: 0x1B_1B1E))
}

enum Type {
    /// Column headers and field labels: small, spaced, unmistakably a console
    /// label rather than content.
    static let label = Font.system(size: 11, weight: .semibold).width(.standard)
    /// `label` one step down: the key column of a verdict row, a table header,
    /// a caption inside a panel where the 11pt console label would compete with
    /// the row it is introducing rather than announce it.
    ///
    /// As with `label`, the tracking is **not** in the font — SwiftUI carries
    /// tracking as a view modifier, not a font trait, which is why
    /// `ConsoleLabel` applies it rather than `Type`. Set it with
    /// `.tracking(0.6)` to hold the same 0.06em ratio `label` gets from
    /// `.tracking(0.7)` at 11pt.
    static let labelSmall = Font.system(size: 10, weight: .semibold).width(.standard)
    /// What a card is about — a human wrote it.
    static let cardTitle = Font.system(size: 13, weight: .medium)
    /// A card title one step down: the name of a row inside a panel.
    static let rowTitle = Font.system(size: 12, weight: .medium)
    /// The story, and other prose read at a glance.
    static let prose = Font.system(size: 11)
    /// Prose given room — the inspector reads a story a point larger than the
    /// card glances at it. Not named `body`, which is `Font.body` already.
    static let bodyProse = Font.system(size: 12)
    /// The demoted "it said" face, and the deliberate visual opposite of
    /// `Type.fact`.
    ///
    /// This is the type-level form of the rule the whole app rests on: **`gh`
    /// is the fact, the agent's prose is a hint.** A run's closing text set in
    /// this face beside its `verifiedOutcome` set in `fact` says which of the
    /// two may be believed before a word of either has been read — the same
    /// judgement the app already makes in code, made visible.
    ///
    /// ⛔ Which is why it is spent on a *claim*, never on a run's closing text
    /// as such. A run that died before its terminal event stores the process's
    /// stderr there and a run Elliot could not start stores Elliot's own
    /// sentence; both were set in this face, which said of a machine's
    /// diagnosis that it might be believed less than `gh` (#288).
    /// `ClosingRemark.isHearsay` is what decides, and `VerdictBlock.style(for:)`
    /// is the one site that reads it.
    ///
    /// It is `bodyProse` italicised rather than a size of its own. What the
    /// agent wrote *is* prose, so demoting it by shrinking it would say it
    /// matters less, when what is meant is that it is less trustworthy. Italic
    /// is the quotation mark.
    static let hearsay = Font.system(size: 12).italic()
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
    // The detail panel deliberately has no constant width here. It is measured
    // *in columns* — `PanelLayout.panelWidth(columnWidth:spans:)` — which is
    // what makes it read as belonging to the column it opened from rather than
    // as a fixed strip at the far edge of the window.
    /// Fixed, because the status bar now carries live numbers that change
    /// width. Left to size itself it has grown and shoved the whole board
    /// upwards before, and a strip that jitters as a cost ticks is worse than
    /// one that truncates.
    static let statusBarHeight: CGFloat = 28
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

    /// The grab area on the panel's outer edge, and the grip drawn in the
    /// middle of it.
    ///
    /// Two numbers rather than one because they answer different questions.
    /// `resizeStripWidth` is how far from the edge a *pointer* still counts as
    /// on the handle; it is deliberately several times the grip it draws,
    /// because a 2pt target is one nobody hits. It is not wider than this
    /// because the strip sits inside the panel, over the outer edge of the
    /// trailing pane — every point added is a point of that pane's scroll bar
    /// taken away.
    ///
    /// `resizeGrip` is what is actually drawn: short, thin, centred, and quiet
    /// enough at rest that it reads as an edge treatment rather than as a
    /// control competing with the panel's content.
    static let resizeStripWidth: CGFloat = 7
    static let resizeGrip: (width: CGFloat, height: CGFloat) = (width: 2, height: 26)
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
