import ElliotModel
import Foundation
import Testing

/// Reading an analysis by what was decided about it (#331).
@Suite("Proposal review")
struct ProposalReviewTests {

    private func proposal(
        _ title: String, _ status: ProposalStatus, acceptedCardID: UUID? = nil
    ) -> StoryProposal {
        StoryProposal(
            analysisID: UUID(), runID: UUID(), repoID: UUID(), angle: .bugs, title: title,
            story: UserStory(role: "dev", want: "w", benefit: "b"),
            status: status, acceptedCardID: acceptedCardID,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private var mixed: [StoryProposal] {
        [
            proposal("first proposed", .proposed),
            proposal("first rejected", .rejected),
            proposal("first accepted", .accepted),
            proposal("second proposed", .proposed),
            proposal("second accepted", .accepted),
        ]
    }

    @Test("Each group holds its own rows, in the order they were harvested")
    func groupsPreserveOrder() {
        #expect(
            ProposalReview.group(mixed, .proposed).map(\.title)
                == ["first proposed", "second proposed"])
        #expect(
            ProposalReview.group(mixed, .accepted).map(\.title)
                == ["first accepted", "second accepted"])
        #expect(ProposalReview.group(mixed, .rejected).map(\.title) == ["first rejected"])
        // Every row lands in exactly one group, so nothing is unreachable.
        #expect(
            ProposalStatus.allCases.map { ProposalReview.group(mixed, $0).count }.reduce(0, +)
                == mixed.count)
    }

    /// ⛔ A missing key and a zero being the same value is the ambiguity this
    /// whole reading is about, so `counts` emits every case.
    @Test("Every status has a count, zero included")
    func countsEmitZeroes() {
        let counts = ProposalReview.counts(mixed)
        #expect(counts == [.proposed: 2, .accepted: 2, .rejected: 1])
        #expect(Set(counts.keys) == Set(ProposalStatus.allCases))

        let empty = ProposalReview.counts([])
        #expect(
            Set(empty.keys) == Set(ProposalStatus.allCases),
            "a picker built on this would silently lose a tab rather than show it at zero")
        #expect(empty.values.allSatisfy { $0 == 0 })
    }

    /// The sentence pair the whole story is about. A lens that proposed nothing
    /// and a lens whose twelve proposals you decided are two different
    /// situations, and the row count cannot tell them apart — only the harvest
    /// can.
    @Test("An empty undecided list says which of the two silences it is")
    func theAmbiguityIsClosed() {
        let foundNothing = ProposalReview.emptyMessage(
            for: .proposed, harvested: 0)
        let allDecided = ProposalReview.emptyMessage(
            for: .proposed, harvested: 12)

        #expect(foundNothing != allDecided)
        #expect(foundNothing.title == "This analysis proposed nothing.")
        #expect(allDecided.title == "Nothing left to decide.")
        #expect(
            !foundNothing.title.contains("decide"),
            "claiming everything was decided when nothing was ever proposed is the defect")
    }

    @Test("A lens still reading outranks both")
    func runningOutranksTheOthers() {
        for harvested in [0, 12] {
            let waiting = ProposalReview.emptyMessage(
                for: .proposed, harvested: harvested, running: ["Bugs", "Tests"])
            #expect(waiting.symbol == "hourglass")
            #expect(waiting.detail.contains("lens by lens"))
            // The lens names are composed here rather than by the view, so a
            // caller cannot splice them into a title it also chose.
            #expect(waiting.title == "Reading — Bugs, Tests")
        }
    }

    @Test("The decided groups each get their own sentence")
    func decidedGroupsHaveTheirOwnEmptyStates() {
        let accepted = ProposalReview.emptyMessage(for: .accepted, harvested: 4)
        let rejected = ProposalReview.emptyMessage(for: .rejected, harvested: 4)
        #expect(accepted != rejected)
        #expect(accepted.title.contains("accepted"))
        #expect(rejected.title.contains("rejected"))

        // ⚠️ Neither borrows the undecided group's answer, and neither reacts to
        // a lens still reading: whether the Bugs run has finished says nothing
        // about whether you have accepted anything. This is the case a view
        // that spliced "Reading — Bugs" over every empty group would get wrong.
        #expect(
            ProposalReview.emptyMessage(for: .accepted, harvested: 0, running: ["Bugs"])
                == accepted)
        #expect(
            ProposalReview.emptyMessage(for: .rejected, harvested: 0, running: ["Bugs"])
                == rejected)
    }

    // MARK: - What an accepted row says about its card

    private func card(_ title: String, _ column: Column) -> Card {
        var card = Card(
            repoID: UUID(), title: title,
            columnEnteredAt: Date(timeIntervalSince1970: 0),
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        card.column = column
        return card
    }

    @Test("An accepted proposal names the card it became, and where that card is")
    func acceptedRowNamesItsCard() {
        let made = card("Bound the await", .inProgress)
        let label = ProposalReview.cardLabel(
            for: proposal("Bound the await", .accepted, acceptedCardID: made.id), card: made)

        #expect(label.contains("Bound the await"))
        #expect(label.contains("In Progress"))
    }

    /// ⚠️ Criterion 2's failure mode, and the one that matters: `accept` commits
    /// the card and *then* writes the backlink, so a `.accepted` proposal with
    /// no resolvable card is a state the engine deliberately produces. It must
    /// still read as accepted.
    @Test("An accepted proposal whose card cannot be found still reads as accepted")
    func aMissingCardIsStillAnAcceptance() {
        let label = ProposalReview.cardLabel(
            for: proposal("Bound the await", .accepted), card: nil)

        #expect(label.hasPrefix("Accepted"))
        #expect(
            label.contains("cannot be found"),
            "the row has to say the card cannot be named rather than say nothing")
    }

    @Test("A card with no title of its own is still located")
    func anUntitledCardStillNamesItsColumn() {
        let untitled = card("", .backlog)
        let label = ProposalReview.cardLabel(
            for: proposal("t", .accepted, acceptedCardID: untitled.id), card: untitled)
        #expect(label.contains("Backlog"))
    }

    @Test("An undecided proposal is never described as accepted")
    func onlyAnAcceptanceGetsACardLabel() {
        #expect(!ProposalReview.cardLabel(for: proposal("t", .proposed), card: nil).hasPrefix("Accepted"))
        #expect(!ProposalReview.cardLabel(for: proposal("t", .rejected), card: nil).hasPrefix("Accepted"))
    }
}
