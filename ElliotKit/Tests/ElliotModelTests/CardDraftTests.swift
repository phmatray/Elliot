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
            evidence: [Evidence(path: "Sources/ElliotAppKit/AnalysisPanelView.swift", line: 910, exists: true)],
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

    /// Not a round-trip in general — seed-then-apply *normalises*, and only
    /// looks like identity because this fixture's criteria are already clean.
    /// The case that shows the difference is below.
    @Test("Applying an untouched draft to an already-normalised proposal changes nothing")
    func applyIsIdentityOnNormalisedInput() {
        let proposal = Self.proposal()
        let draft = CardDraft(proposal: proposal)
        #expect(draft.applied(to: proposal) == proposal)
    }

    /// What a harvested proposal actually looks like: an analysis emits padded
    /// and empty criteria, and `ProposedStory.story` does not clean them on the
    /// way in. So opening the editor and pressing Save *without typing* is a
    /// normalising write, not a no-op — worth knowing before someone reads
    /// "round-trips" as a promise that the stored proposal is untouched.
    @Test("Seed-then-apply normalises a proposal that arrived untidy")
    func applyNormalisesUntidyInput() {
        let untidy = Self.proposal(
            story: UserStory(
                role: "reviewer", want: "to correct one", benefit: "it lands right",
                acceptanceCriteria: ["  padded  ", "", "   "]
            )
        )
        let unedited = CardDraft(proposal: untidy).applied(to: untidy)
        #expect(unedited.story.acceptanceCriteria == ["padded"])
        #expect(unedited != untidy, "saving without typing still tidies the criteria")
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

    /// A **defensive** branch, not a supported path — this pins what it does,
    /// not that anyone may rely on it.
    ///
    /// Two things close it: `init(proposal:)` pins `isStory`, and
    /// `CardFieldsEditor` re-pins it on appear in `.story` kind. So no editor
    /// can reach `applied(to:)` with a note-mode draft. Held here because the
    /// alternatives if it ever were reached are worse than a no-op: trapping
    /// would crash the window, and writing an empty story would erase a real
    /// one silently. If a future caller finds this branch doing something
    /// useful, that caller is the bug.
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

@Suite("A draft's labels")
struct CardDraftLabelsTests {

    private static let then = Date(timeIntervalSince1970: 1_700_000_000)

    private static func card(labels: [String]) -> Card {
        Card(
            repoID: UUID(), title: "Run log", labels: labels,
            columnEnteredAt: then, createdAt: then, updatedAt: then
        )
    }

    @Test("A draft seeded from a card carries that card's labels, in order")
    func seededFromCard() {
        let draft = CardDraft(card: Self.card(labels: ["documentation", "bug"]))
        #expect(draft.labels == ["documentation", "bug"])
    }

    @Test("A draft written from scratch asks for no labels")
    func freshDraftHasNone() {
        #expect(CardDraft().labels == [])
    }

    /// Labels are never required, and adding one must never *become* a way to
    /// make an otherwise-fine card unsaveable. The Save gate is the title and
    /// the story, exactly as before.
    @Test("Labels do not enter the Save gate, in either direction")
    func labelsNeverAffectValidity() {
        var draft = CardDraft(title: "Run log", role: "dev", want: "the log", benefit: "no terminal")
        #expect(draft.isValid)
        draft.labels = ["bug"]
        #expect(draft.isValid)
        draft.labels = []
        #expect(draft.isValid)

        draft.title = "  "
        draft.labels = ["bug"]
        #expect(!draft.isValid, "a label is not a substitute for a name")
    }

    /// The mutation lives on the draft rather than in the view's closure so
    /// `swift test` can hold it — a chip list that appended a duplicate would
    /// send `--label "bug" --label "bug"` and render two identical chips, and
    /// nothing in a SwiftUI body can be asserted.
    @Test("Toggling adds at the end, and toggling again removes")
    func toggleIsIdempotent() {
        var draft = CardDraft()
        draft.toggleLabel("bug")
        draft.toggleLabel("documentation")
        #expect(draft.labels == ["bug", "documentation"])

        draft.toggleLabel("bug")
        #expect(draft.labels == ["documentation"], "toggling an existing label removes it")

        draft.toggleLabel("documentation")
        #expect(draft.labels == [])
    }

    /// GitHub refuses a second casing of a label that exists, so `Bug` and
    /// `bug` are one label. A toggle that treated them as two would let a card
    /// ask for both and show two chips for one label.
    @Test("A label already asked for in another casing is the same label")
    func toggleIsCaseInsensitive() {
        var draft = CardDraft()
        draft.toggleLabel("Bug")
        draft.toggleLabel("bug")
        #expect(draft.labels == [], "the second toggle removed the first")

        draft.toggleLabel("bug")
        draft.toggleLabel("BUG")
        #expect(draft.labels == [])
    }

    @Test("Blank input is not a label")
    func blanksAreNotLabels() {
        var draft = CardDraft()
        draft.toggleLabel("   ")
        draft.toggleLabel("")
        #expect(draft.labels == [])
    }
}

@Suite("What the editor knows about a repository's labels")
struct RepositoryLabelsTests {

    @Test("A repository that answered offers what it has")
    func knownOffersItsOwn() {
        let known = RepositoryLabels.known(["bug", "enhancement", "documentation"])
        #expect(known.offerable == ["bug", "enhancement", "documentation"])
    }

    @Test("A label the repository does not have is reported missing, whatever its casing")
    func missingIsNamed() {
        let known = RepositoryLabels.known(["bug", "Enhancement"])
        #expect(!known.isMissing("bug"))
        #expect(!known.isMissing("BUG"), "GitHub refuses a second casing, so this is the same label")
        #expect(!known.isMissing("enhancement"))
        #expect(known.isMissing("documentation"))
    }

    /// A repository really can have no labels, and saying so is a finding the
    /// card should show. It is the *other* case that must not be confused with
    /// it — see below.
    @Test("A repository with no labels is a finding: everything is missing")
    func emptyIsAFinding() {
        let known = RepositoryLabels.known([])
        #expect(known.offerable == [])
        #expect(known.isMissing("bug"))
    }

    /// The load-bearing case, and the same duty `labelsCheck` records one
    /// screen over: **a failure to ask is not a finding about the answer.**
    /// Marking every label missing here would paint a card full of red on a
    /// laptop that is merely offline, and offering an empty picker would say
    /// "this repository has no labels" on no evidence at all.
    @Test("A repository that could not be reached accuses nothing")
    func unavailableAccusesNothing() {
        let unknown = RepositoryLabels.unavailable
        #expect(unknown.offerable == [])
        #expect(!unknown.isMissing("bug"))
        #expect(!unknown.isMissing("something nobody has"))
        #expect(!unknown.isKnown, "and it says which case it is, so the editor can explain itself")
        #expect(RepositoryLabels.known([]).isKnown)
    }
}

@Suite("Turning gh's answer into what the editor may claim")
struct RepositoryLabelsFromGHTests {

    @Test("An answer becomes the repository's list, empty answer included")
    func answerBecomesKnown() {
        #expect(RepositoryLabels(ghAnswer: ["bug", "documentation"])
            == .known(["bug", "documentation"]))
        #expect(RepositoryLabels(ghAnswer: []) == .known([]))
    }

    /// `GHClient.labels` **throws** rather than answering `[]` when `gh` fails,
    /// and this is the other end of that decision: no answer maps to
    /// `.unavailable`, never to a list. Collapsing them here would undo the
    /// distinction one call up the stack, which is precisely the bug #170's own
    /// comment describes.
    @Test("No answer is not an empty list")
    func noAnswerIsUnavailable() {
        #expect(RepositoryLabels(ghAnswer: nil) == .unavailable)
        #expect(RepositoryLabels(ghAnswer: nil) != .known([]))
    }

    /// The editor has to say *why* it is offering nothing, and the two reasons
    /// are opposite. Silence under `.unavailable` reads as "this repository has
    /// no labels" — a confident wrong answer, which this codebase treats as
    /// worse than an error.
    @Test("Only the unreachable case explains itself, and it does not claim there are none")
    func explanationSeparatesTheTwoSilences() {
        #expect(RepositoryLabels.known(["bug"]).explanation == nil)
        #expect(RepositoryLabels.known([]).explanation != nil, "no labels is a finding worth saying")

        let excuse = try! #require(RepositoryLabels.unavailable.explanation)
        #expect(!excuse.isEmpty)
        #expect(RepositoryLabels.known([]).explanation != excuse, "two silences, two sentences")
    }
}
