/// What Preflight last said about a repository, as the rule engine sees it.
///
/// Three states and not a `Bool`, and the third one is the whole reason this
/// type exists rather than a flag on `Repo`.
///
/// `PreflightService.isBlocking` was `results.contains { $0.status == .fail }`,
/// so on an empty array — a repository nobody had swept yet — it answered
/// **`false`**. A repository that had never been looked at was therefore
/// indistinguishable, at the type level, from one that was looked at and
/// passed. That was not a bug in `isBlocking`; it is what a two-valued answer to
/// a three-valued question always does, and it is how a gate that three separate
/// documents claimed existed turned out never to have been written.
///
/// ⛔ That function is gone since #302, and the shape with it: `PreflightReading`
/// cannot be built without a moment it was taken at, so the screens hold one per
/// repository and an **absent** reading is this enum's first case. Nothing in
/// the app now turns a pile of checks into a verdict without saying whether
/// anybody looked.
///
/// So: a caller that has not measured cannot *say* "passing" by accident. It has
/// to say `notChecked`, and every reader decides what that means for itself.
public enum PreflightState: String, Codable, CaseIterable, Sendable, Hashable {

    /// Nobody has swept this repository since it was registered, or since this
    /// database was migrated.
    ///
    /// ⚠️ **This does not block a move, and that is a decision rather than an
    /// oversight.** Blocking would freeze the board for the first seconds of
    /// every launch — every repository is in this state until the sweep reaches
    /// it — and would freeze it *permanently* whenever the sweep cannot finish,
    /// which is a live risk: the sweep runs a networked `gh label list` per
    /// repository and GitHub rate-limits at 5 000/h.
    ///
    /// What the state buys is that the board can **say** "not read yet" instead
    /// of inheriting a pass, and that turning this into a refusal later is one
    /// line in `evaluateMove` rather than a re-derivation.
    case notChecked

    /// The sweep ran and found no failing check.
    case passing

    /// The sweep ran and at least one check failed.
    ///
    /// This refuses a move. Which check failed is not carried here on purpose —
    /// naming it in the column caption also wants the card's badge to become a
    /// control that opens Preflight scrolled to that check, which is a change to
    /// what a card *is* and belongs in its own change with its own on-screen
    /// pass.
    case failing

    /// Whether a move may proceed in a repository in this state.
    ///
    /// Written as a property rather than as a comparison at each site so the
    /// answer has one home — the mistake being corrected here is that the
    /// question was answered in four views and in no rule.
    public var allowsMoves: Bool {
        switch self {
        case .passing, .notChecked: true
        case .failing: false
        }
    }
}
