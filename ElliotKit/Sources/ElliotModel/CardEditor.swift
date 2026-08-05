import Foundation

/// Edit mode for the card detail sheet: whether it is editing, and the draft
/// it is editing.
///
/// Two fields rather than an `Optional<CardDraft>`, because the sheet binds a
/// child editor to the draft. A binding derived from an optional with
/// `Binding($draft)` is backed by `BindingOperations.ForceUnwrapping`, which
/// traps the moment the optional empties while the child is still mounted —
/// every Cancel, every successful Save. Keeping the draft non-optional means
/// there is no projection to trap, and `end()` destroys nothing underneath a
/// view that is still on screen.
///
/// It lives here rather than in the sheet for the same reason `CardDraft` does:
/// `ElliotApp` is an executable target with no tests, so a transition written
/// in a `View` is a transition nothing can check.
public struct CardEditor: Sendable, Hashable {
    /// Read-only from outside: the flag only ever moves through `begin` and
    /// `end`, so it cannot drift away from what those transitions guarantee.
    public private(set) var isEditing: Bool
    public var draft: CardDraft

    public init() {
        self.isEditing = false
        self.draft = CardDraft()
    }

    /// Enters edit mode seeded from the card. Refuses once the card is filed:
    /// from that point the issue is the record, not the card.
    ///
    /// Seeding on every `begin` is what stops a cancelled edit coming back —
    /// `end()` keeps the old draft on purpose, and this overwrites it.
    public mutating func begin(from card: Card) {
        guard card.issueNumber == nil else { return }
        draft = CardDraft(card: card)
        isEditing = true
    }

    /// Leaves edit mode. The draft is deliberately kept — nothing reads it
    /// while `isEditing` is false, and retaining it is what keeps a child's
    /// binding valid through the layout pass that still runs before teardown.
    public mutating func end() {
        isEditing = false
    }
}
