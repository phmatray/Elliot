import Foundation

/// An open proposal editor: which proposal, and what has been typed into it.
///
/// The panel's own type comment promises that hiding it loses nothing — "the
/// runs keep going and the observation keeps landing proposals, so re-showing
/// finds everything that arrived meanwhile" — and the state that would break
/// that was moved to the model. The setup form and the triage selection were
/// moved; the editor was not. So `⌘⌥A`, the Analyse toggle or the header `✕`
/// removed `.analysis` from `boardOrder`, tore the subtree down, and a retyped
/// title plus eight acceptance criteria went with it, in silence.
///
/// ⛔ **One value, not two properties.** An `editingID` beside an optional
/// `draft` has two states that must never occur — an id with no draft, a draft
/// with no id — and nothing to stop them. Pairing them is the same reason
/// `CardOutcome` carries the card and the move together.
public struct ProposalEdit: Sendable, Hashable {
    public var proposalID: UUID
    public var draft: CardDraft

    public init(proposalID: UUID, draft: CardDraft) {
        self.proposalID = proposalID
        self.draft = draft
    }

    /// Whether this edit still has something to be applied to.
    ///
    /// ⚠️ A proposal can be accepted or rejected over MCP while the panel is
    /// hidden, and re-applying a draft over a decided proposal is worse than
    /// losing it: an accepted one already has a Backlog card carrying its text.
    /// So survival is decided against **the rows still open for decision**, not
    /// against the analysis as a whole.
    ///
    /// The parameter is the ids rather than the proposals so the rule stays
    /// pure and the caller keeps deciding what "open" means — which is the same
    /// filter the list already renders.
    public func survives(amongOpen ids: Set<UUID>) -> Bool {
        ids.contains(proposalID)
    }
}
