import ElliotModel

/// What the analysis panel's setup footer says, decided once.
///
/// The setup slot answers four questions with one line — why Start is refused,
/// why the last Start did not happen, why the next one would be refused, and
/// what it would otherwise spend — and
/// until #138 it answered them with a chain of `if`s in `AnalysisPanelView`'s
/// body. That is where the defect lived rather than merely where it showed:
/// `swift test` cannot enter a view body, so the branch that could have
/// rendered a failed start was unreachable for two issues (#134, #136) with
/// nothing able to say so. Views render and dispatch; they do not judge.
///
/// It holds no `Color`. `Tone` is mapped to `Palette` at the one place that
/// draws it, so a test asserts the decision rather than a colour — and a value
/// that cannot name a colour cannot be where a sixth consequence accent
/// arrives.
///
/// It lives in `ElliotAppKit` rather than `ElliotModel` on the #72 rule: put a
/// rule in `ElliotModel` because it is pure **and shared with the MCP helper**.
/// This one is not shared — the helper has no footer — and `ElliotAppKit` is a
/// library its own tests already reach.
struct AnalysisFooterMessage: Equatable {
    /// Two accents, and deliberately not five.
    ///
    /// `BrandColorTests` pins the five consequence accents, and the spec for
    /// this fix names a new one as a design decision rather than a side effect
    /// of it. A refusal already means *"a move was refused, or a run failed"*.
    enum Tone: Equatable {
        case armed
        case refused
    }

    let text: String
    let symbol: String
    let tone: Tone

    /// The setup slot's whole decision, in precedence order.
    ///
    /// **Refusal ▸ failure ▸ clash ▸ consequence**, and each step of that order
    /// is a claim rather than a preference:
    ///
    /// - A **refusal** wins because Start is `.disabled` while one stands, so
    ///   nothing the reader does to the lenses can be attempted and a failure
    ///   underneath it is about an attempt that can no longer be repeated. The
    ///   refusal is the only one of the four that names something to go and do.
    /// - A **failure** outranks the clash and the consequence because toggling a
    ///   lens changes what the *next* start would do; it does not un-fail the
    ///   last one. Falling back to a sentence about the next press is precisely
    ///   the bug — a sentence about what the button is about to spend, printed
    ///   after it has already failed to spend it.
    /// - A **clash** outranks the consequence for the mirror-image reason. Both
    ///   are about the next press, and the clash is the one that says it will
    ///   not happen; a cost printed over a press that starts nothing is the same
    ///   defect one step further along.
    ///
    /// ⛔ **The clash does not reduce the count, it replaces the sentence.**
    /// `AnalysisService.start` refuses the whole set on the first clash before
    /// it saves anything, so "reads the repository 7 times" for eight armed
    /// lenses with one busy would be a figure for something that cannot happen.
    /// The all-or-nothing rule is stated here because it is the one place the
    /// reader meets it before pressing.
    ///
    /// ⚠️ **And it is worded as the reading it is.** The clash comes from a
    /// snapshot the panel took; a lens can finish, or start, in between. Hence
    /// *"when the lenses were last checked"* rather than a claim about now —
    /// the same distinction the board draws between what `gh` established and
    /// what an agent said.
    ///
    /// The three consequence sentences are the ones the view used to hold, moved
    /// verbatim so the copy cannot drift between here and there.
    static func setup(
        angleCount: Int,
        clashing: [AnalysisAngle] = [],
        failure: String?,
        refusal: String?
    ) -> AnalysisFooterMessage {
        if let refusal {
            return AnalysisFooterMessage(
                text: refusal, symbol: "exclamationmark.octagon.fill", tone: .refused)
        }
        if let failure {
            return AnalysisFooterMessage(
                text: failure, symbol: "exclamationmark.triangle.fill", tone: .refused)
        }
        if !clashing.isEmpty {
            let names = Self.list(clashing.map(\.title))
            let plural = clashing.count == 1
            return AnalysisFooterMessage(
                text: "\(names) \(plural ? "was" : "were") still reading when the lenses were last "
                    + "checked — Start is all or nothing, so untick \(plural ? "it" : "them") or "
                    + "wait.",
                // The lens strip's own word for a run in flight, so the tile and
                // the sentence about it read as one thing.
                symbol: "hourglass",
                // ⛔ Not a sixth accent, and not a third `Tone`. The sentence
                // predicts a refusal — Start will throw — and `refused` is
                // already what this value says for "Pick at least one lens.",
                // which is just as mild and just as self-inflicted. A new tone
                // here is a design decision, and this is not the change that
                // should make it.
                tone: .refused)
        }
        switch angleCount {
        case 0:
            // Armed nothing, so this is a refusal too — it just happens to be
            // one the reader can lift from this very screen.
            return AnalysisFooterMessage(
                text: "Pick at least one lens.", symbol: "bolt.fill", tone: .refused)
        case 1:
            return AnalysisFooterMessage(
                text: "Reads the repository once.", symbol: "bolt.fill", tone: .armed)
        default:
            return AnalysisFooterMessage(
                text: "Reads the repository \(angleCount) times — one run per lens.",
                symbol: "bolt.fill", tone: .armed)
        }
    }

    /// `"Bugs"`, `"Bugs and Tech debt"`, `"Bugs, Tests and Tech debt"`.
    ///
    /// Here rather than `ListFormatter`: that one is locale-aware and this
    /// sentence is not — the rest of it is written in English in this file, and
    /// a half-localised sentence reads worse than an unlocalised one. It also
    /// keeps the value testable against a literal.
    private static func list(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        guard items.count > 1 else { return last }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }
}
