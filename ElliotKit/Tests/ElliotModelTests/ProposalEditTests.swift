import Foundation
import Testing

@testable import ElliotModel

/// An open editor is one value: which proposal, and what has been typed.
@Suite("Proposal edit")
struct ProposalEditTests {

    @Test("An edit survives while its proposal is still open for decision")
    func survivesWhileOpen() {
        let id = UUID()
        let edit = ProposalEdit(proposalID: id, draft: CardDraft(title: "Mine"))
        #expect(edit.survives(amongOpen: [id]))
        #expect(edit.survives(amongOpen: [id, UUID()]))
    }

    /// ⛔ A proposal accepted or rejected elsewhere is no longer open, and a
    /// draft must not be re-applied over it: an accepted proposal already has a
    /// Backlog card carrying its text.
    @Test("A decided proposal no longer carries its edit")
    func decidedProposalsDoNotSurvive() {
        let edit = ProposalEdit(proposalID: UUID(), draft: CardDraft(title: "Mine"))
        #expect(edit.survives(amongOpen: []) == false)
        #expect(edit.survives(amongOpen: [UUID(), UUID()]) == false)
    }

    /// ⛔ Two properties would have two states that must never occur — an id
    /// with no draft, a draft with no id — and nothing to stop them. This is the
    /// same reason `CardOutcome` carries the card and the move together, so the
    /// test is really about the *shape*: an edit cannot be half-present.
    @Test("An edit always carries both halves")
    func bothHalvesTravelTogether() {
        var edit = ProposalEdit(proposalID: UUID(), draft: CardDraft(title: "One"))
        let original = edit
        edit.draft.title = "Two"
        #expect(edit != original)
        #expect(edit.proposalID == original.proposalID)
    }
}
