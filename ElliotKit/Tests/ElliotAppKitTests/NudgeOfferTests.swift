import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// What `⌘→` and `⌘←` say they will do.
///
/// Every column already stated its consequence in words on screen; the keyboard
/// path — the only path for someone who cannot drag — stated nothing. `⌘→` on a
/// Done card was enabled, did nothing, and left no refusal on the card the way a
/// drop does.
@Suite("Nudge offer")
@MainActor
struct NudgeOfferTests {

    private static let fixed = Date(timeIntervalSince1970: 1_770_000_000)

    private func seeded(_ column: Column, enabled: Bool = true) -> (AppModel, Card) {
        var repo = Repo(
            path: "/tmp/nudge", nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        repo.isEnabled = enabled
        let card = Card(
            repoID: repo.id, title: "A card", column: column,
            columnEnteredAt: Self.fixed, createdAt: Self.fixed, updatedAt: Self.fixed)
        let model = AppModel()
        model.testOnlySeed(repos: [repo], cards: [card])
        model.selectedCardID = card.id
        return (model, card)
    }

    @Test("With no card selected, there is nothing to offer")
    func noSelectionOffersNothing() {
        let model = AppModel()
        #expect(model.nudgeOffer(forward: true).isEnabled == false)
        #expect(model.nudgeOffer(forward: true).title == "Advance")
        #expect(model.nudgeOffer(forward: false).title == "Move back")
    }

    /// ⛔ The whole point: the title states the consequence, so a reader knows
    /// what `⌘→` is about to start before pressing it.
    @Test("The title names what the move would do")
    func theTitleNamesTheConsequence() {
        let (model, card) = seeded(.backlog)
        let offer = model.nudgeOffer(forward: true)
        #expect(offer.title.hasPrefix("Advance — "))
        #expect(offer.title != "Advance")
        // And it is the same sentence the board already shows for that move,
        // not a second wording: both go through `preview`.
        let expected = Consequence.of(model.preview(card, to: .todo)).summary
        #expect(offer.title == "Advance — \(expected)")
        #expect(offer.detail == expected)
    }

    @Test("Move back names its own consequence, not the forward one")
    func backwardIsItsOwnAnswer() {
        let (model, _) = seeded(.inReview)
        let forward = model.nudgeOffer(forward: true)
        let back = model.nudgeOffer(forward: false)
        #expect(forward.title != back.title)
        #expect(back.title.hasPrefix("Move back"))
    }

    /// ⚠️ At the edge the item stays **pressable**. Pressing it is how the reason
    /// gets said — exactly as dropping a card on a column that refuses it writes
    /// the refusal on the card. Disabling it restores the original defect one
    /// step over: the reader presses, nothing happens, nothing explains why.
    @Test("Advancing from Done is offered, so that pressing it can explain")
    func theEdgeStaysPressable() {
        let (model, _) = seeded(.done)
        let offer = model.nudgeOffer(forward: true)
        #expect(offer.isEnabled)
        #expect(offer.detail?.contains("nothing to advance to") == true)
    }

    @Test("Moving back from Backlog is offered for the same reason")
    func theOtherEdgeStaysPressable() {
        let (model, _) = seeded(.backlog)
        let offer = model.nudgeOffer(forward: false)
        #expect(offer.isEnabled)
        #expect(offer.detail?.contains("nothing to move back to") == true)
    }

    /// ⛔ The regression: `nudgeSelection` returned silently at the ends.
    @Test("Pressing at the edge writes a refusal on the card")
    func theEdgeRefusesAudibly() async {
        let (model, card) = seeded(.done)
        await model.nudgeSelection(forward: true)

        #expect(model.refusal?.cardID == card.id)
        #expect(model.refusal?.message.contains("nothing to advance to") == true)
        #expect(model.status.contains("nothing to advance to"))
        // And nothing moved: there is no board behind a seeded model, and the
        // point of the refusal is that there was no move to make.
        #expect(model.card(id: card.id)?.column == .done)
    }

    /// The hint line said a flat "⌘→ advance" for every card, including the ones
    /// where `⌘→` does nothing at all.
    @Test("The status hint speaks for the card that is selected")
    func theHintIsAboutThisCard() {
        #expect(AppModel().selectionHint == "↑↓←→ pick a card")

        let (backlog, _) = seeded(.backlog)
        let (done, _) = seeded(.done)
        #expect(backlog.selectionHint != done.selectionHint)
        #expect(done.selectionHint.contains("nothing to advance to"))
        #expect(backlog.selectionHint.contains("esc deselect"))
    }

    /// A refused move still reads as a refusal rather than as an invitation —
    /// the wording is `Consequence`'s, so this is really checking that
    /// `nudgeOffer` consults it rather than deciding for itself.
    @Test("A disabled repository's card still gets a truthful title")
    func aRefusedMoveIsStated() {
        let (model, card) = seeded(.backlog, enabled: false)
        let offer = model.nudgeOffer(forward: true)
        let consequence = Consequence.of(model.preview(card, to: .todo))
        #expect(consequence.isRefused)
        #expect(offer.title == "Advance — \(consequence.summary)")
    }
}
