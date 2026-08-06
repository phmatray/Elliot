import Foundation
import Testing

@testable import ElliotModel

private let then = Date(timeIntervalSince1970: 1_700_000_000)

@Suite("A card's analysis lens")
struct CardAngleTests {

    /// The default is "no lens", not a lens meaning nothing. Every card the
    /// board has ever made — the New-story sheet, `board_create_card`, the
    /// GitHub import — arrives through an initialiser that never mentions one.
    @Test("A card written by hand has no lens")
    func handWrittenCardHasNoAngle() {
        let card = Card(
            repoID: UUID(), title: "Run log",
            columnEnteredAt: then, createdAt: then, updatedAt: then
        )
        #expect(card.angle == nil)
    }

    @Test("A card made from a proposal keeps the lens it was found through")
    func acceptedCardKeepsItsAngle() {
        let card = Card(
            repoID: UUID(), title: "Bound the await", angle: .bugs,
            columnEnteredAt: then, createdAt: then, updatedAt: then
        )
        #expect(card.angle == .bugs)
    }

    /// The whole feature is "six lenses, six marks". Two lenses sharing a glyph
    /// would draw perfectly and be indistinguishable on the board, which is the
    /// one thing the mark exists to prevent — and a seventh lens added without
    /// a mark of its own is exactly how that happens.
    @Test("Every lens has a mark, and no two lenses share one")
    func everyAngleHasADistinctSymbol() {
        let symbols = AnalysisAngle.allCases.map(\.symbol)
        #expect(symbols.allSatisfy { !$0.isEmpty })
        #expect(Set(symbols).count == AnalysisAngle.allCases.count)
    }

    /// The lens has to survive the round trip, because the card is stored as
    /// JSON in more than one place and read back by a second process.
    ///
    /// Absence has to survive it too, and separately: a `nil` that decodes as a
    /// lens would put a mark on every hand-written card, and a lens that
    /// decodes as `nil` would silently drop the provenance this whole issue is
    /// about. Encoding one card and asserting the other case is not covered
    /// would miss whichever direction was broken.
    @Test("The lens survives a JSON round trip, and so does its absence")
    func angleSurvivesCoding() throws {
        for angle in AnalysisAngle.allCases.map(Optional.some) + [nil] {
            let card = Card(
                repoID: UUID(), title: "Bound the await", angle: angle,
                columnEnteredAt: then, createdAt: then, updatedAt: then
            )
            let data = try JSONEncoder().encode(card)
            let decoded = try JSONDecoder().decode(Card.self, from: data)
            #expect(decoded.angle == angle)
        }
    }
}
