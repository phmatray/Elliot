import Foundation
import Testing

@testable import ElliotModel

/// The transitions a proposal's status may take — and the one this feature
/// exists to keep unsayable.
///
/// `claimProposal` took only a `to:` and hardcoded `.proposed` as the status it
/// moved out of, so a mis-clicked Reject was permanent (#292). The repair had a
/// tempting wrong shape: a free `(from:to:)` pair, which makes
/// `.accepted → .proposed` writable at every call site and puts a proposal whose
/// Backlog card already exists back on the triage list for a second Accept.
///
/// These tests are about the *shape*, not about any one call. A defect that has
/// been made unrepresentable still needs something asserting it stayed that way,
/// because the next person to need a fourth transition will reach for the pair
/// again.
@Suite("Proposal claim")
struct ProposalClaimTests {

    @Test("The three claims are the three moves, and each is spelled out")
    func theTransitions() {
        #expect(ProposalClaim.accept.from == .proposed)
        #expect(ProposalClaim.accept.to == .accepted)
        #expect(ProposalClaim.reject.from == .proposed)
        #expect(ProposalClaim.reject.to == .rejected)
        #expect(ProposalClaim.restore.from == .rejected)
        #expect(ProposalClaim.restore.to == .proposed)
    }

    /// The claim the type exists to refuse. A proposal that has been accepted
    /// has a card on the board; putting it back where it can be accepted again
    /// is how one story grows two cards, and no call site should be able to
    /// write it by passing the wrong argument.
    @Test("Nothing can be claimed out of .accepted")
    func acceptedIsTerminal() {
        let outOfAccepted = ProposalClaim.allCases.filter { $0.from == .accepted }
        #expect(
            outOfAccepted.isEmpty,
            """
            \(outOfAccepted) moves a proposal out of .accepted. A proposal that reached .accepted \
            has a Backlog card; every route back to .proposed is a route to a second card for one \
            story (#292)
            """
        )
    }

    /// The other half of the same guarantee, from the destination side: exactly
    /// one claim can make a proposal acceptable-again, and it starts from the
    /// only status where no card exists.
    @Test("Only a rejected proposal can become open again")
    func onlyRejectionIsUndone() {
        let intoProposed = ProposalClaim.allCases.filter { $0.to == .proposed }
        #expect(intoProposed == [.restore])
        #expect(intoProposed.allSatisfy { $0.from == .rejected })
    }

    /// A claim that did not move the row anywhere would be a no-op the store
    /// reports as a win, and a caller entitled to create a card off it.
    @Test("No claim is a self-transition")
    func everyClaimMoves() {
        for claim in ProposalClaim.allCases {
            #expect(claim.from != claim.to, "\(claim) claims a status it is already in")
        }
    }

    /// A negative needs its positive witness: an enum trimmed to one case would
    /// satisfy every filter above vacuously.
    @Test("All three claims exist")
    func theSetIsWhatItSaysItIs() {
        #expect(Set(ProposalClaim.allCases) == [.accept, .reject, .restore])
    }

    // MARK: - Which rejected rows may come back

    private func proposal(
        status: ProposalStatus, acceptedCardID: UUID? = nil
    ) -> StoryProposal {
        StoryProposal(
            analysisID: UUID(), runID: UUID(), repoID: UUID(), angle: .bugs,
            title: "A story",
            story: UserStory(role: "developer", want: "a thing", benefit: "a reason"),
            status: status, acceptedCardID: acceptedCardID,
            createdAt: Date(timeIntervalSince1970: 1_754_600_000)
        )
    }

    @Test("Only a rejected proposal is offered a Restore")
    func onlyRejectedRowsRestore() {
        #expect(proposal(status: .rejected).isRestorable)
        #expect(!proposal(status: .proposed).isRestorable)
        #expect(!proposal(status: .accepted).isRestorable)
    }

    /// The trap this issue names outright. `acceptedCardID` is a card that
    /// exists on the board; a rejected row still carrying one must be read back
    /// as history, never offered as something to put on the list again.
    @Test("A rejected proposal that already produced a card is not restorable")
    func aCardMeansNoWayBack() {
        #expect(!proposal(status: .rejected, acceptedCardID: UUID()).isRestorable)
        #expect(
            !proposal(status: .accepted, acceptedCardID: UUID()).isRestorable,
            "and neither is the ordinary accepted row it came from")
    }
}
