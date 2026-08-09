import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// Which editors may offer labels at all, and what the panel does with the
/// ones a card already carries.
///
/// The decision is named on `CardFieldsEditor.Kind` rather than written as a
/// `kind == .card` in the body, for the reason the type's own comment gives:
/// `swift test` cannot see a SwiftUI body, so a rule written there is a rule
/// nothing can hold.
@Suite("A card's labels in the editor")
struct CardLabelEditorTests {

    /// ⛔ The proposal editor must not offer labels, and this is not tidiness.
    /// `CardDraft.applied(to:)` writes a `StoryProposal`, which has **nowhere
    /// to put them** — it takes the title and the story and nothing else. An
    /// editor that showed a label picker there would accept clicks, render
    /// chips, and discard every one of them on Save: the exact failure
    /// `CardFieldsEditor.Kind` was introduced to prevent, one field later.
    @Test("Only the card editor offers labels — a proposal has nowhere to keep them")
    func onlyTheCardEditorOffersLabels() {
        #expect(CardFieldsEditor.Kind.card.offersLabels)
        #expect(!CardFieldsEditor.Kind.story.offersLabels)
    }

    /// Acceptance criterion 4: readable **without opening an editor**. A label
    /// only visible in edit mode would be a decision the board does not show,
    /// which is the whole complaint this issue starts from.
    @Test("A card carrying labels shows them in the panel without going into edit mode")
    func labelsAreVisibleOutsideTheEditor() {
        let then = Date(timeIntervalSince1970: 1_700_000_000)
        let carrying = Card(
            repoID: UUID(), title: "Run log", labels: ["bug"],
            columnEnteredAt: then, createdAt: then, updatedAt: then
        )
        let bare = Card(
            repoID: UUID(), title: "Run log",
            columnEnteredAt: then, createdAt: then, updatedAt: then
        )

        #expect(PanelLayout.showsLabels(carrying))
        // And nothing at all for a card that asked for none — an empty rail
        // with a caption reads as a thing that failed to load.
        #expect(!PanelLayout.showsLabels(bare))
    }
}
