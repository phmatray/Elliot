import Foundation

/// A move of a proposal from one status to another — and, by construction, the
/// only ones there are.
///
/// `BoardStore.claimProposal` took only a `to:` and hardcoded `.proposed` as the
/// status it moved *out* of, so `.rejected → .proposed` could not be expressed
/// at all and a mis-clicked Reject was permanent (#292).
///
/// ⛔ **The obvious repair — a second `from:` parameter — is the wrong shape,
/// and it is worth being precise about why.** A free `(from:to:)` pair makes
/// `.accepted → .proposed` sayable at every call site, and that transition puts
/// a proposal whose Backlog card already exists back on the triage list, where
/// the next Accept makes a second card for it. Defending against that with a
/// rule ("never pass `.accepted` as `from`") is a rule somebody has to remember;
/// a closed set of three cases is a call that cannot be written. There is no
/// `from` to get wrong because there is no `from` to pass.
///
/// The same reasoning is why this is an enum rather than a `static let` table of
/// pairs: `switch` over it is exhaustive, so a fourth transition has to answer
/// both questions below before anything compiles.
public enum ProposalClaim: String, CaseIterable, Codable, Sendable, Hashable {

    /// `proposed → accepted`, immediately before the card is made. Winning this
    /// is what entitles a caller to create one.
    case accept

    /// `proposed → rejected`. Marks, never deletes: an analysis you have been
    /// through should still read as what it found, including what you turned
    /// down — which is only true if something can read it back, hence `restore`.
    case reject

    /// `rejected → proposed`. The undo for a Reject that sits 6pt from Accept.
    ///
    /// Deliberately **not** a fourth `ProposalStatus`. `Analysis` has no `state`
    /// field for the same reason its own comment gives — a second reservoir of
    /// truth drifts on the first crash — and a `.restored` status would be one:
    /// two values meaning "open for decision", with every filter in the app
    /// having to remember both.
    case restore

    /// The status a row must already be in for this claim to change anything.
    public var from: ProposalStatus {
        switch self {
        case .accept, .reject: .proposed
        case .restore: .rejected
        }
    }

    /// The status the row is moved to.
    public var to: ProposalStatus {
        switch self {
        case .accept: .accepted
        case .reject: .rejected
        case .restore: .proposed
        }
    }
}
