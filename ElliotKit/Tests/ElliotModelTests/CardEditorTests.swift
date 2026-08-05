import Foundation
import Testing

@testable import ElliotModel

@Suite("Card editor")
struct CardEditorTests {

    private func card(
        title: String = "Edit a card",
        story: UserStory? = nil,
        body: String = "",
        issueNumber: Int? = nil
    ) -> Card {
        let now = Date()
        return Card(
            repoID: UUID(), title: title, body: body, story: story,
            issueNumber: issueNumber,
            columnEnteredAt: now, createdAt: now, updatedAt: now
        )
    }

    @Test("A fresh editor is not editing")
    func fresh() {
        let editor = CardEditor()
        #expect(!editor.isEditing)
        #expect(editor.draft == CardDraft())
    }

    @Test("Beginning on an unfiled card seeds the draft from that card")
    func beginSeedsFromCard() {
        let story = UserStory(
            role: "developer", want: "to edit a card", benefit: "a typo is not fatal",
            acceptanceCriteria: ["Edit appears", "Save calls updateCard"]
        )
        var editor = CardEditor()

        editor.begin(from: card(title: "Edit a card", story: story))

        #expect(editor.isEditing)
        #expect(editor.draft.title == "Edit a card")
        #expect(editor.draft.isStory)
        #expect(editor.draft.want == "to edit a card")
        #expect(editor.draft.benefit == "a typo is not fatal")
        #expect(editor.draft.criteria == ["Edit appears", "Save calls updateCard"])
    }

    @Test("Beginning on a filed card is refused, and clobbers nothing")
    func beginRefusedOnFiledCard() {
        var editor = CardEditor()

        editor.begin(from: card(title: "Already filed", issueNumber: 42))

        #expect(!editor.isEditing, "once filed, the issue is the record — not the card")
        #expect(editor.draft == CardDraft(), "a refused begin must not seed the draft either")
    }

    /// The regression test for the `EXC_BREAKPOINT` of #9.
    ///
    /// The sheet hands a child editor a binding into `draft`. If leaving edit
    /// mode destroyed the draft — as setting an `Optional<CardDraft>` back to
    /// `nil` did — that binding would read a value that is no longer there on
    /// the layout pass that still runs before the child is torn down. Keeping
    /// the draft is what makes the child's binding safe through teardown.
    @Test("Ending edit mode keeps the draft, so a live child binding stays valid")
    func endKeepsTheDraft() {
        var editor = CardEditor()
        editor.begin(from: card(title: "Edit a card", body: "a note", issueNumber: nil))
        let editedDraft = editor.draft

        editor.end()

        #expect(!editor.isEditing)
        #expect(editor.draft == editedDraft, "nothing may be destroyed under a mounted child")
    }

    @Test("Editing again after a cancel re-seeds from the card rather than resurrecting the draft")
    func beginAfterEndReseeds() {
        let subject = card(title: "Edit a card", body: "a note")
        var editor = CardEditor()
        editor.begin(from: subject)
        editor.draft.title = "typed but cancelled"
        editor.end()

        editor.begin(from: subject)

        #expect(editor.isEditing)
        #expect(editor.draft.title == "Edit a card", "a cancelled edit must not come back")
    }
}
