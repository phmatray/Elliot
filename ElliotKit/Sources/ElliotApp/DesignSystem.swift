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

enum Type {
    /// Column headers and field labels: small, spaced, unmistakably a console
    /// label rather than content.
    static let label = Font.system(size: 11, weight: .semibold).width(.standard)
    /// What a card is about — a human wrote it.
    static let cardTitle = Font.system(size: 13, weight: .medium)
    /// The story, and other prose read at a glance.
    static let prose = Font.system(size: 11)
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
    static let cardRadius: CGFloat = 7
    static let columnRadius: CGFloat = 10
    static let railHeight: CGFloat = 2
    static let gutter: CGFloat = 10
}

enum Elapsed {
    /// How long a run has been going, in the fact face's idiom. Shared by the
    /// card strip and the analysis lens strip so a run reads the same wherever
    /// it is watched.
    static func short(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return seconds < 60
            ? "\(seconds)s"
            : "\(seconds / 60)m \(String(format: "%02d", seconds % 60))s"
    }
}

/// The uppercase, letter-spaced console label used for column names and field
/// captions.
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
