import Foundation
import Testing

@testable import ElliotModel

@Suite("Card draft")
struct CardDraftTests {

    @Test("A story draft needs a label and all three story parts")
    func validity() {
        var draft = CardDraft(title: "Run log", role: "developer", want: "the log", benefit: "no terminal")
        #expect(draft.isValid)

        draft.title = "   "
        #expect(!draft.isValid)

        draft.title = "Run log"
        draft.benefit = ""
        #expect(!draft.isValid)
    }

    @Test("A note draft needs only a label")
    func noteValidity() {
        var draft = CardDraft(title: "Spike", isStory: false, note: "look at GRDB observation")
        #expect(draft.isValid)

        draft.note = ""
        #expect(draft.isValid, "a note card may be a bare label")

        draft.title = ""
        #expect(!draft.isValid)
    }

    @Test("Story mode derives the story and an empty body; note mode does the reverse")
    func derivation() {
        var draft = CardDraft(
            title: "Run log", role: "developer", want: "the log", benefit: "no terminal",
            criteria: ["the log tails live", "   ", ""]
        )
        #expect(draft.story?.acceptanceCriteria == ["the log tails live"])
        #expect(draft.body.isEmpty)

        draft.isStory = false
        draft.note = "just a note"
        #expect(draft.story == nil)
        #expect(draft.body == "just a note")
    }

    @Test("Seeding from a story card round-trips the story")
    func seedFromStoryCard() {
        let story = UserStory(
            role: "developer", want: "to edit a card", benefit: "a typo is not fatal",
            acceptanceCriteria: ["Edit appears", "Save calls updateCard"]
        )
        let now = Date()
        let card = Card(
            repoID: UUID(), title: "Edit a card", story: story,
            columnEnteredAt: now, createdAt: now, updatedAt: now
        )

        let draft = CardDraft(card: card)
        #expect(draft.isStory)
        #expect(draft.title == "Edit a card")
        #expect(draft.criteria == ["Edit appears", "Save calls updateCard"])
        #expect(draft.story == story)
        #expect(draft.isValid)
    }

    @Test("Removing the last criterion leaves one empty row for the editor")
    func removingLastCriterion() {
        var draft = CardDraft(title: "Run log", criteria: ["only one"])
        draft.removeCriterion(at: 0)
        #expect(draft.criteria == [""], "the editor must always have a row to render")
    }

    @Test("Removing one of several criteria removes just that one")
    func removingOneCriterion() {
        var draft = CardDraft(title: "Run log", criteria: ["a", "b", "c"])
        draft.removeCriterion(at: 1)
        #expect(draft.criteria == ["a", "c"])
    }

    @Test("Removing a stale index is ignored rather than trapping")
    func removingOutOfRange() {
        var draft = CardDraft(title: "Run log", criteria: ["a"])
        draft.removeCriterion(at: 5)
        #expect(draft.criteria == ["a"])
    }

    @Test("Seeding from a note card picks note mode and keeps one criterion row")
    func seedFromNoteCard() {
        let now = Date()
        let card = Card(
            repoID: UUID(), title: "Spike", body: "look at GRDB observation",
            columnEnteredAt: now, createdAt: now, updatedAt: now
        )

        let draft = CardDraft(card: card)
        #expect(!draft.isStory)
        #expect(draft.note == "look at GRDB observation")
        #expect(draft.criteria == [""], "the editor always renders at least one criterion row")
        #expect(draft.role == "developer", "toggling to story mode must not present a blank role")
    }

    // MARK: - Seeding from a proposal, and writing one back

    /// A proposal with enough provenance to notice if `applied(to:)` touched
    /// any of it. Every field that is *not* editable carries a distinctive
    /// value so the round-trip assertions are about the real thing.
    private static func proposal(
        title: String = "Edit a proposal",
        story: UserStory = UserStory(
            role: "reviewer", want: "to correct a proposal", benefit: "a near-miss is not retyped",
            acceptanceCriteria: ["The editor binds a draft", "Save uses isValid"]
        )
    ) -> StoryProposal {
        StoryProposal(
            analysisID: UUID(), runID: UUID(), repoID: UUID(),
            angle: .techDebt,
            title: title,
            story: story,
            rationale: "two editors for the same three fields",
            evidence: [Evidence(path: "Sources/ElliotAppKit/AnalysisWindow.swift", line: 910, exists: true)],
            effort: .large,
            status: .proposed,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @Test("Seeding from a proposal carries the label and all three story parts across")
    func seedFromProposal() {
        let proposal = Self.proposal()
        let draft = CardDraft(proposal: proposal)

        #expect(draft.title == "Edit a proposal")
        #expect(draft.role == "reviewer")
        #expect(draft.want == "to correct a proposal")
        #expect(draft.benefit == "a near-miss is not retyped")
        #expect(draft.criteria == ["The editor binds a draft", "Save uses isValid"])
        #expect(draft.note.isEmpty, "a proposal has nowhere to put a note")
    }

    @Test("A draft seeded from a proposal is a story, and cannot open in note mode")
    func seedFromProposalPinsStoryMode() {
        let draft = CardDraft(proposal: Self.proposal())
        #expect(draft.isStory, "a proposal is always a story")
        #expect(draft.story != nil)
        #expect(draft.isValid)
    }

    @Test("A proposal with no acceptance criteria still seeds a row for the editor")
    func seedFromProposalWithoutCriteria() {
        let bare = Self.proposal(
            story: UserStory(role: "reviewer", want: "to correct one", benefit: "it lands right")
        )
        let draft = CardDraft(proposal: bare)
        #expect(draft.criteria == [""], "the editor must always have a row to render")
    }

    @Test("Applying an unedited draft returns an equal proposal")
    func applyRoundTrips() {
        let proposal = Self.proposal()
        let draft = CardDraft(proposal: proposal)
        #expect(draft.applied(to: proposal) == proposal)
    }

    @Test("Applying an edited draft carries the label and the story back")
    func applyCarriesEdits() {
        let proposal = Self.proposal()
        var draft = CardDraft(proposal: proposal)
        draft.title = "Correct a proposal"
        draft.want = "to correct it in place"
        draft.criteria = ["One field set", "One rule"]

        let edited = draft.applied(to: proposal)
        #expect(edited.title == "Correct a proposal")
        #expect(edited.story.want == "to correct it in place")
        #expect(edited.story.acceptanceCriteria == ["One field set", "One rule"])
        #expect(edited.story.role == "reviewer", "an untouched part is still carried")
    }

    @Test("Applying drops blank and whitespace-only criteria")
    func applyDropsBlankCriteria() {
        let proposal = Self.proposal()
        var draft = CardDraft(proposal: proposal)
        draft.criteria = ["kept", "   ", "", "\n", " also kept "]

        let edited = draft.applied(to: proposal)
        #expect(edited.story.acceptanceCriteria == ["kept", "also kept"])
    }

    @Test("Applying leaves the proposal's provenance untouched")
    func applyLeavesProvenanceAlone() {
        let proposal = Self.proposal()
        var draft = CardDraft(proposal: proposal)
        draft.title = "Something else entirely"

        let edited = draft.applied(to: proposal)
        #expect(edited.id == proposal.id)
        #expect(edited.analysisID == proposal.analysisID)
        #expect(edited.runID == proposal.runID)
        #expect(edited.repoID == proposal.repoID)
        #expect(edited.angle == proposal.angle)
        #expect(edited.rationale == proposal.rationale)
        #expect(edited.evidence == proposal.evidence)
        #expect(edited.effort == proposal.effort)
        #expect(edited.status == proposal.status)
        #expect(edited.createdAt == proposal.createdAt)
    }

    /// The `nil` branch of `applied(to:)` is unreachable through
    /// `init(proposal:)`, which pins `isStory`. It is reachable by hand, and
    /// what it must not do is trap or write an empty story over a real one.
    @Test("A draft forced into note mode leaves the proposal's story alone")
    func applyFromNoteModeKeepsTheStory() {
        let proposal = Self.proposal()
        var draft = CardDraft(proposal: proposal)
        draft.isStory = false
        draft.title = "Still renamed"

        let edited = draft.applied(to: proposal)
        #expect(edited.title == "Still renamed")
        #expect(edited.story == proposal.story, "a note has no story to write")
    }
}
