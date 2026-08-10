import Foundation

/// Why an unattended agent may not be started against a repository right now.
///
/// **One rule, three callers**: `AnalysisService.start`, the appraisal — neither
/// of which passes through a board transition — and `AnalysisRefusal`, which
/// renders it for the toolbar's tooltip and the analysis panel's footer and adds
/// the remedy each sentence names.
///
/// It is here, pure, because the only gate that had ever existed on the analysis
/// path was a computed property on a SwiftUI model, and #151 removed the
/// `.disabled(…)` it fed — correctly, because a toggle you cannot switch off is
/// worse than one that opens onto an explanation, and very nearly taking the gate
/// with it. An appraisal makes that worse rather than better: it passes through
/// **no** transition at all, so `evaluateMove`, `allowSideEffects` and
/// `repoPreflight` never see it. These are the only unattended agents in Elliot
/// that start outside *moving a card is the act of execution*, and this is their
/// point of application.
///
/// ⚠️ **Not a second copy of `evaluateMove`'s two guards, though it agrees with
/// them, in their order.** That function decides the whole transition matrix for a
/// *move* — a gesture a person made, which `MoveBlock` answers in the board's own
/// vocabulary. This one answers a *start* that no gesture and no column can
/// explain, so it has no transition to consult and no `MoveBlock` to return. What
/// the two must not do is disagree about the order, which is why the argument for
/// it is written on ``refusal(repo:preflight:)`` and cross-referenced there.
public enum UnattendedStartRefusal: Sendable, Hashable {

    /// The reader switched this repository off.
    case repoDisabled

    /// Preflight ran and at least one check failed.
    ///
    /// Deliberately not carrying *which* check: `ElliotModel` cannot see
    /// `BlockedBadge`, and naming the finding is the caller's job — it is also
    /// what lets the analysis footer offer the way to it while a service, which
    /// has no screen to send anyone to, simply refuses.
    case preflightBlocked

    /// The whole sentence, ready to show.
    ///
    /// Each one names the place to go rather than the rule that fired — "fix it
    /// there first" tells you what to do; "refused" does not.
    ///
    /// ⚠️ **These two strings shipped, verbatim.** `Consequence.reason` reads the
    /// first and `AnalysisRefusal` reads both, so `AnalysisSessionTests` and
    /// `AnalysisRefusalTests` compare against them without knowing this type
    /// exists — and `UnattendedStartRefusalTests` pins them here so a reword is a
    /// deliberate edit rather than a drift.
    public var sentence: String {
        switch self {
        case .repoDisabled:
            "This repository is switched off in Preflight."
        case .preflightBlocked:
            "A Preflight check is failing for this repository — fix it there first."
        }
    }

    /// `nil` when an unattended run may start.
    ///
    /// ⛔ **`preflight` is a three-valued `PreflightState`, never a `Bool`, and
    /// that is the whole reason this signature looks the way it does.**
    /// `PreflightService.isBlocking` was `results.contains { $0.status == .fail }`
    /// read through `repoChecks[id] ?? []`, so a repository nobody had swept
    /// answered **`false`** — *not asked* and *asked and clear* were one value,
    /// which is how a gate three documents claimed existed turned out never to
    /// have been written. It was deleted in #302 along with that shape. A caller
    /// that has not measured cannot say `passing` here by accident; it has to say
    /// ``PreflightState/notChecked`` and take the answer this rule gives for it.
    ///
    /// ⚠️ **The parameter decides, not `repo.preflightVerdict`.** The persisted
    /// column is the right value for the board — a card's badge may legitimately
    /// show a reading from a minute ago — but a service that has just swept holds a
    /// fresher verdict than the row it loaded, and an unattended start is the one
    /// caller that should be judged on the fresher one
    /// (`PreflightReading.verdict(of:)` folds an absent reading into
    /// `notChecked`). Reading the row here would make that unsayable while still
    /// compiling.
    ///
    /// ⚠️ **`notChecked` does not refuse, and it is a named branch rather than a
    /// fall-through.** `evaluateMove` lets it through for reasons `PreflightState`
    /// writes out: blocking would freeze the board for the first seconds of every
    /// launch, and permanently whenever a rate-limited `gh label list` stops the
    /// sweep finishing. Changing that is then a deliberate edit to a named case
    /// with a named test behind it —
    /// `UnattendedStartRefusalTests.notCheckedDoesNotRefuse` — instead of an
    /// accident of a two-valued answer.
    ///
    /// ⛔ **The order is load-bearing**, and it is `evaluateMove`'s own
    /// (`repoIsEnabled` at `RuleEngine.swift:240`, `repoPreflight` at `:257`). A
    /// repository can be both, and switching one on is a switch the reader threw:
    /// offering the diagnosis first sends someone hunting a finding when the answer
    /// is a toggle they turned off themselves. `Consequence.reason` keeps
    /// `.repoDisabled` and `.repoBlocked` apart in as many words for the same
    /// reason.
    public static func refusal(repo: Repo, preflight: PreflightState) -> UnattendedStartRefusal? {
        if !repo.isEnabled { return .repoDisabled }
        switch preflight {
        case .failing: return .preflightBlocked
        case .passing: return nil
        case .notChecked: return nil
        }
    }
}
