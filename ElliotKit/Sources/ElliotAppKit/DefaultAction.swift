/// Who may claim Return.
///
/// The rule is one sentence: **`.keyboardShortcut(.defaultAction)` may be
/// claimed only by a control that commits text the reader has typed.**
///
/// It exists because Return had two claimants that can be on screen at the same
/// time, on the same card, resolving between saving an edit and merging to a
/// default branch on github.com — with nothing in the code deciding which.
/// `PanelLayout.headerRegions` returns `[.mergeConfirmation]` and then
/// `guard !isEditing else { return regions }`, so the merge confirmation
/// deliberately survives edit mode; `DetailPanelView` renders it as
/// `MergeConfirmation`, whose merge button carried a default action, while
/// "Save changes" carried one too. A card imported from a pull request that
/// closes no issue reaches both at once: `issueNumber == nil` shows "Edit
/// story", `prNumber != nil` lets a merge be armed.
///
/// The resolution is not "scope Return better". It is that **the one
/// irreversible act in the product must never be what Return does by
/// accident**, so `Merge PR` claims nothing at all and is reached by pressing
/// it. That is the same argument `AnalysisPanelView` already makes for its
/// Start button, which starts up to eight unattended runs and is therefore
/// denied a default action outright — this generalises it from one control to a
/// rule, and gives the rule a gate.
///
/// The gate is `DefaultActionTests`, which reads the source of `ElliotAppKit`
/// and fails naming the file when a claimant appears that is not listed here.
/// A rule written only in prose is a rule right up until someone is in a hurry;
/// this codebase has that lesson on file three times over.
public enum DefaultAction {

    /// A control that is allowed to be what Return does.
    public struct Claimant: Sendable, Hashable {
        /// The file it lives in, by bare name. `DefaultActionTests` walks both
        /// `Sources/ElliotAppKit` and `Sources/ElliotApp` (#251) and matches on
        /// this name, which is unique across the two.
        public let file: String
        /// The button's literal label, exactly as written in the source.
        ///
        /// The label rather than a line number, because a line number goes
        /// stale on the next edit above it and a label does not — and because
        /// the rule is about *which control*, which is what the label names.
        public let label: String
        /// What the reader typed that pressing it commits.
        public let commits: String

        public init(file: String, label: String, commits: String) {
            self.file = file
            self.label = label
            self.commits = commits
        }
    }

    /// Every control in the app that may claim Return.
    ///
    /// Three, and each one commits text: a story being written, a story being
    /// rewritten, and a proposal being edited before it becomes a card. Nothing
    /// that spawns a run is here, and nothing irreversible is here.
    ///
    /// Adding a fourth is a real decision, not a formality — the three panes
    /// these live in can share the board window, so a fourth claimant is a
    /// fourth way for Return to mean something the reader did not intend.
    public static let claimants: [Claimant] = [
        Claimant(
            file: "NewStoryView.swift",
            label: "Add to backlog",
            commits: "a new user story"
        ),
        Claimant(
            file: "DetailPanelView.swift",
            label: "Save changes",
            commits: "an edit to a card that has not been filed yet"
        ),
        Claimant(
            file: "AnalysisPanelView.swift",
            label: "Save",
            commits: "an edit to a proposal before it becomes a card"
        ),
    ]

    /// The controls that are deliberately *denied* a default action, and why.
    ///
    /// Kept beside the allow-list rather than left implicit, because "this one
    /// has no shortcut" is invisible in a diff: a control that never had one and
    /// a control that had one removed on purpose look identical. Naming them is
    /// what makes re-adding one read as reversing a decision.
    public static let denied: [Claimant] = [
        Claimant(
            file: "Sheets.swift",
            label: "Merge PR",
            commits: "nothing — it merges to a default branch on github.com"
        ),
        Claimant(
            file: "AnalysisPanelView.swift",
            label: "Start",
            commits: "nothing — it starts up to eight unattended runs"
        ),
    ]

    /// How many claims the source of `ElliotAppKit` should contain.
    public static var expectedClaimCount: Int { claimants.count }

    /// The labels Return is allowed to belong to.
    public static var sanctionedLabels: Set<String> {
        Set(claimants.map(\.label))
    }
}
