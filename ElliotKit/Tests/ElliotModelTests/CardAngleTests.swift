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

@Suite("The labels a card asks for")
struct CardLabelsTests {

    /// Empty is the default, and every existing construction site keeps
    /// compiling unchanged because of it. A card that asked for a label nobody
    /// chose would put a label on an issue nobody chose.
    @Test("A card asks for no labels unless someone said otherwise")
    func labelsDefaultToEmpty() {
        let card = Card(
            repoID: UUID(), title: "Run log",
            columnEnteredAt: then, createdAt: then, updatedAt: then
        )
        #expect(card.labels == [])
    }

    /// Order is the writer's, and it is kept: `--label` is repeatable and a
    /// reshuffle in a list a human is looking at reads as a change.
    @Test("Labels survive a JSON round trip, in the order they were written")
    func labelsSurviveCoding() throws {
        let card = Card(
            repoID: UUID(), title: "Run log", labels: ["documentation", "bug"],
            columnEnteredAt: then, createdAt: then, updatedAt: then
        )
        let decoded = try JSONDecoder().decode(Card.self, from: try JSONEncoder().encode(card))
        #expect(decoded.labels == ["documentation", "bug"])
    }

    /// ⚠️ The one that a plain `public var labels: [String] = []` fails.
    ///
    /// Swift's synthesised decoder demands the key regardless of the default,
    /// and `BoardStore.openReadOnly` accepts a database older than the code
    /// reading it — so a card written before this column existed has to decode,
    /// or the MCP helper refuses every read in exactly the window that
    /// tolerance was built for. `OlderDatabaseTests` catches it end to end;
    /// this catches it here, where the cause is.
    @Test("A card encoded before labels existed still decodes, asking for none")
    func absentLabelsDecodeAsNone() throws {
        // The same JSON `Card` produced one commit before `labels` was added:
        // every other key, and no `labels`.
        var fields = try #require(
            try JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(
                    Card(
                        repoID: UUID(), title: "Written before labels",
                        columnEnteredAt: then, createdAt: then, updatedAt: then
                    )
                )
            ) as? [String: Any]
        )
        #expect(fields.removeValue(forKey: "labels") != nil, "the fixture must start with the key")

        let older = try JSONSerialization.data(withJSONObject: fields)
        let decoded = try JSONDecoder().decode(Card.self, from: older)
        #expect(decoded.labels == [])
        #expect(decoded.title == "Written before labels")
    }

    /// The wrapper must be invisible in the encoded form, or adopting it would
    /// be its own migration: a `{"wrappedValue": […]}` in the column would not
    /// be readable as the `[String]` every other array field is stored as.
    @Test("Labels encode as a bare array, exactly as an unwrapped [String] would")
    func labelsEncodeUnwrapped() throws {
        let card = Card(
            repoID: UUID(), title: "Run log", labels: ["bug"],
            columnEnteredAt: then, createdAt: then, updatedAt: then
        )
        let fields = try #require(
            try JSONSerialization.jsonObject(with: try JSONEncoder().encode(card))
                as? [String: Any]
        )
        #expect(fields["labels"] as? [String] == ["bug"])
    }

    @Test("The three lenses that mean a label say so")
    func lensesWithAnHonestLabel() {
        #expect(AnalysisAngle.bugs.suggestedLabel == "bug")
        #expect(AnalysisAngle.docsAndDX.suggestedLabel == "documentation")
        #expect(AnalysisAngle.features.suggestedLabel == "enhancement")
    }

    /// The point of the whole issue is that a label is a decision someone made
    /// and can see. A lens whose finding could as easily be a defect as a
    /// feature — a quick win, a UX gap — has no honest label, and answering one
    /// anyway would be the guess dressed as a decision this exists to stop.
    /// `nil` costs nothing: the editor still offers every label the repository
    /// has.
    @Test("A lens with no honest label says nothing rather than guessing")
    func lensesWithNoHonestLabel() {
        for angle in [AnalysisAngle.quickWins, .techDebt, .tests, .uxAndUI, .bestPractices] {
            #expect(angle.suggestedLabel == nil, "\(angle) invented a label")
        }
    }

    /// A suggestion Preflight does not check for would arrive on the card
    /// already marked missing — a pre-fill that reads as a mistake the moment
    /// it appears. So the map may only name labels `LabelPolicy` requires, and
    /// this fails when a sixth lens is given a label the policy has not been
    /// taught.
    @Test("Every suggested label is one Elliot requires the repository to have")
    func suggestionsStayInsideThePolicy() {
        let required = Set(LabelPolicy.default.map(\.name))
        for angle in AnalysisAngle.allCases {
            guard let label = angle.suggestedLabel else { continue }
            #expect(required.contains(label), "\(angle) suggests \(label), which no policy requires")
        }
    }
}
