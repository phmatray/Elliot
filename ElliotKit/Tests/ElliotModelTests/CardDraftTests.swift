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
}
