/// What the analysis panel's setup footer says, decided once.
///
/// The setup slot answers three questions with one line — why Start is refused,
/// why the last Start did not happen, and what the next one will spend — and
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
    /// **Refusal ▸ failure ▸ consequence**, and each step of that order is a
    /// claim rather than a preference:
    ///
    /// - A **refusal** wins because Start is `.disabled` while one stands, so
    ///   nothing the reader does to the lenses can be attempted and a failure
    ///   underneath it is about an attempt that can no longer be repeated. The
    ///   refusal is the only one of the three that names something to go and do.
    /// - A **failure** outranks the consequence because toggling a lens changes
    ///   what the *next* start would spend; it does not un-fail the last one.
    ///   Falling back to the consequence line is precisely the bug — a sentence
    ///   about what the button is about to spend, printed after it has already
    ///   failed to spend it.
    ///
    /// The three consequence sentences are the ones the view used to hold, moved
    /// verbatim so the copy cannot drift between here and there.
    static func setup(angleCount: Int, failure: String?, refusal: String?) -> AnalysisFooterMessage {
        if let refusal {
            return AnalysisFooterMessage(
                text: refusal, symbol: "exclamationmark.octagon.fill", tone: .refused)
        }
        if let failure {
            return AnalysisFooterMessage(
                text: failure, symbol: "exclamationmark.triangle.fill", tone: .refused)
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
}
