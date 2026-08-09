import Foundation

/// The editable shape of a card, and the one rule for when it may be saved.
///
/// Lives here rather than in the sheet that renders it because `ElliotApp` is an
/// executable target with no tests: a validation rule written in a `View` is a
/// validation rule nothing can check. Both the new-card sheet and the edit mode
/// of the detail sheet bind to this, so there is one field set and one rule.
public struct CardDraft: Codable, Sendable, Hashable {
    /// The board label.
    public var title: String
    /// Story mode when true, plain note when false — the segmented picker.
    public var isStory: Bool
    public var role: String
    public var want: String
    public var benefit: String
    /// Always holds at least one element so the editor renders a row; blank
    /// entries are dropped on the way out.
    public var criteria: [String]
    public var note: String

    /// The labels this card asks its issue to carry, in the order they were
    /// chosen. Never part of `isValid`: a card with no labels is a perfectly
    /// good card, and it is the common one.
    public var labels: [String]

    public init(
        title: String = "",
        isStory: Bool = true,
        role: String = "developer",
        want: String = "",
        benefit: String = "",
        criteria: [String] = [""],
        note: String = "",
        labels: [String] = []
    ) {
        self.title = title
        self.isStory = isStory
        self.role = role
        self.want = want
        self.benefit = benefit
        self.criteria = criteria.isEmpty ? [""] : criteria
        self.note = note
        self.labels = labels
    }

    /// Seeds a draft from an existing card. The story fields keep their
    /// defaults for a note card, so switching to story mode does not present a
    /// blank role.
    public init(card: Card) {
        let story = card.story
        self.init(
            title: card.title,
            isStory: story != nil,
            role: story?.role ?? "developer",
            want: story?.want ?? "",
            benefit: story?.benefit ?? "",
            criteria: story?.acceptanceCriteria ?? [],
            note: card.body,
            labels: card.labels
        )
    }

    /// Seeds a draft from a proposal awaiting correction.
    ///
    /// `isStory` is pinned true rather than derived: a `StoryProposal` carries
    /// a `UserStory` and has nowhere to put a note, so a proposal editor that
    /// could reach note mode would present fields whose contents are discarded
    /// on save — and `isValid` would quietly weaken to "the label is
    /// non-blank", accepting the half-written story it exists to refuse. The
    /// pin lives here rather than in the view because this is the layer
    /// `swift test` can see.
    ///
    /// Only `title` and the story are taken. A proposal's rationale, evidence,
    /// effort and angle are its provenance, not its editable shape.
    public init(proposal: StoryProposal) {
        let story = proposal.story
        self.init(
            title: proposal.title,
            isStory: true,
            role: story.role,
            want: story.want,
            benefit: story.benefit,
            // The designated init re-seeds `[""]` when this is empty, so the
            // editor always has a row; that rule is not written twice.
            criteria: story.acceptanceCriteria
        )
    }

    /// The proposal this draft produces: the same proposal with its label and
    /// story replaced, blank criteria dropped by `story`.
    ///
    /// The counterpart to `init(proposal:)`, and the same move as
    /// `VerifiedOutcome.applied(to:attribution:)` — what an edit *means* is
    /// decided here, once, rather than reconciled inside a Save closure.
    ///
    /// `story` is non-nil for any draft that came from `init(proposal:)`. A
    /// draft forced into note mode by hand falls back to the proposal's
    /// existing story rather than trapping or writing an empty one over it:
    /// a note has no story to contribute, and losing one to a mode that
    /// cannot be reached through the editor would be an absurd way to fail.
    public func applied(to proposal: StoryProposal) -> StoryProposal {
        var edited = proposal
        edited.title = title
        edited.story = story ?? proposal.story
        return edited
    }

    /// Drops a criterion row, re-seeding an empty row so the editor always has
    /// something to render.
    ///
    /// One mutation rather than a remove-then-check in the view: the detail
    /// sheet edits through a derived `Binding`, whose getter still reports the
    /// pre-removal array until the body re-evaluates — so a second read in the
    /// same action would see a stale, non-empty list and skip the re-seed. The
    /// index is checked because `ForEach(indices, id: \.self)` can hand back a
    /// row that is already gone.
    public mutating func removeCriterion(at index: Int) {
        guard criteria.indices.contains(index) else { return }
        criteria.remove(at: index)
        if criteria.isEmpty { criteria = [""] }
    }

    /// Adds a label the card does not ask for yet, or takes one off.
    ///
    /// A mutation on the draft rather than set arithmetic inside the picker's
    /// closure, for the reason the rest of this type exists: `swift test` cannot
    /// see a SwiftUI body, so a rule written there is a rule nothing can hold.
    ///
    /// Case-insensitive, because GitHub is — it refuses a second casing of a
    /// label that exists. A toggle that read `Bug` and `bug` as two labels would
    /// let one card ask for both, draw two chips for one label, and send
    /// `--label "Bug" --label "bug"` to a skill that can only apply one.
    ///
    /// Appends rather than sorting: the order is the writer's, and a list that
    /// reshuffled itself as you clicked would read as something going wrong.
    public mutating func toggleLabel(_ name: String) {
        let wanted = name.trimmed()
        guard !wanted.isEmpty else { return }
        if let existing = labels.firstIndex(where: { $0.lowercased() == wanted.lowercased() }) {
            labels.remove(at: existing)
        } else {
            labels.append(wanted)
        }
    }

    /// Whether the card already asks for this label, under any casing.
    public func asksFor(_ name: String) -> Bool {
        labels.contains { $0.lowercased() == name.trimmed().lowercased() }
    }

    /// The story this draft produces, blank criteria dropped. `nil` in note mode.
    public var story: UserStory? {
        guard isStory else { return nil }
        return UserStory(
            role: role,
            want: want,
            benefit: benefit,
            acceptanceCriteria: criteria.map { $0.trimmed() }.filter { !$0.isEmpty }
        )
    }

    /// The body this draft produces: the note in note mode, empty in story mode.
    public var body: String { isStory ? "" : note }

    /// Saveable once the label is non-blank and, in story mode, the story is
    /// complete. A half-written story would be refused at the first drag
    /// anyway; refusing it here says so earlier.
    public var isValid: Bool {
        guard !title.trimmed().isEmpty else { return false }
        return isStory ? (story?.isComplete ?? false) : true
    }
}
