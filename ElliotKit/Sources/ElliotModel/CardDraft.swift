import Foundation

/// The editable shape of a card, and the one rule for when it may be saved.
///
/// Lives here rather than in the sheet that renders it because `ElliotApp` is an
/// executable target with no tests: a validation rule written in a `View` is a
/// validation rule nothing can check. Both the new-card sheet and the edit mode
/// of the detail sheet bind to this, so there is one field set and one rule.
public struct CardDraft: Sendable, Hashable {
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

    public init(
        title: String = "",
        isStory: Bool = true,
        role: String = "developer",
        want: String = "",
        benefit: String = "",
        criteria: [String] = [""],
        note: String = ""
    ) {
        self.title = title
        self.isStory = isStory
        self.role = role
        self.want = want
        self.benefit = benefit
        self.criteria = criteria.isEmpty ? [""] : criteria
        self.note = note
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
            note: card.body
        )
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
