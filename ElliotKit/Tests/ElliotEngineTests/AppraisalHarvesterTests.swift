import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine

/// The harvester reads the **artifact or nothing**.
///
/// `ProposalHarvester` falls back to a fenced JSON block in the closing message,
/// and that is right for it: a proposal lands in a review queue a person reads.
/// An appraisal lands in a card field an unattended ranking sorts on, so prose
/// salvaged from a chat message would become a measurement. Leaving the card
/// unappraised and saying so is the better answer — the three failure tests
/// below are what says so.
@Suite("Appraisal harvester")
struct AppraisalHarvesterTests {

    private struct Fixture {
        var store: BoardStore
        var repo: Repo
        var card: Card
        var run: SkillRun
        var artifactURL: URL
        var root: URL

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    /// A throwaway repository with one real file, so evidence resolution has
    /// something true and something false to tell apart.
    private func makeFixture() async throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elliot-appraise-\(UUID().uuidString)", isDirectory: true)
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "// real".write(
            to: sources.appendingPathComponent("Real.swift"), atomically: true, encoding: .utf8)

        let store = try BoardStore.inMemory()
        let repo = Repo(path: root.path, nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        try await store.saveRepo(repo)

        let now = Date()
        let card = Card(
            repoID: repo.id, title: "A story", columnEnteredAt: now,
            createdAt: now, updatedAt: now
        )
        try await store.saveCard(card)

        let run = SkillRun.card(
            cardID: card.id, repoID: repo.id, kind: .appraiseCards, prompt: "…",
            cwd: repo.path,
            logPath: root.appendingPathComponent("run.ndjson").path,
            stderrPath: root.appendingPathComponent("run.log").path,
            createdAt: now
        )
        try await store.saveRun(run)

        return Fixture(
            store: store, repo: repo, card: card, run: run,
            artifactURL: root.appendingPathComponent("appraisal.json"),
            root: root
        )
    }

    @Test("A good artifact lands on the card, with evidence resolved")
    func harvestsFromArtifact() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        try """
        {"effort":"small","evidence":["Sources/Real.swift:3","Sources/Nowhere.swift"]}
        """.write(to: fixture.artifactURL, atomically: true, encoding: .utf8)

        let report = await AppraisalHarvester(store: fixture.store).harvest(
            run: fixture.run, repo: fixture.repo, artifactURL: fixture.artifactURL
        )
        #expect(report.harvestSource == .artifact)
        #expect(report.kept == 1)
        #expect(report.dropped.isEmpty)

        let card = try #require(try await fixture.store.card(id: fixture.card.id))
        #expect(card.effort == .small)
        #expect(card.appraisedAt != nil)
        let evidence = try #require(card.evidence)
        #expect(evidence.count == 2)
        #expect(evidence[0].exists)
        #expect(evidence[1].exists == false)
    }

    @Test("No artifact leaves the card unappraised, and the report names the path")
    func noArtifact() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        let report = await AppraisalHarvester(store: fixture.store).harvest(
            run: fixture.run, repo: fixture.repo, artifactURL: fixture.artifactURL
        )
        #expect(report.harvestSource == .none)
        #expect(report.kept == 0)
        #expect(report.dropped.contains { $0.contains(fixture.artifactURL.path) })

        let card = try #require(try await fixture.store.card(id: fixture.card.id))
        #expect(card.appraisedAt == nil)
        #expect(card.effort == nil)
        #expect(card.evidence == nil)
    }

    @Test("An artifact that cannot be read leaves the card unappraised, and names the failure")
    func unreadableArtifact() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        // A directory at the artifact path forces a read failure without
        // chmod: `Data(contentsOf:)` throws rather than returning nothing, and
        // that is a different fact from "no artifact was written" — see
        // Override 2 in the task-9 handoff.
        try FileManager.default.createDirectory(
            at: fixture.artifactURL, withIntermediateDirectories: true)

        let report = await AppraisalHarvester(store: fixture.store).harvest(
            run: fixture.run, repo: fixture.repo, artifactURL: fixture.artifactURL
        )
        #expect(report.harvestSource == .none)
        #expect(report.kept == 0)
        #expect(report.dropped.contains { $0.contains("could not be read") })
        // Must not be confused with the "no artifact was written" sentence:
        // the file is right there, just unreadable as data.
        #expect(!report.dropped.contains { $0.contains("No artifact was written") })

        let card = try #require(try await fixture.store.card(id: fixture.card.id))
        #expect(card.appraisedAt == nil)
    }

    @Test("An empty artifact leaves the card unappraised, and says it was empty")
    func emptyArtifact() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        try Data().write(to: fixture.artifactURL)

        let report = await AppraisalHarvester(store: fixture.store).harvest(
            run: fixture.run, repo: fixture.repo, artifactURL: fixture.artifactURL
        )
        #expect(report.harvestSource == .none)
        #expect(report.dropped.contains { $0.contains("empty") })
        #expect(try await fixture.store.card(id: fixture.card.id)?.appraisedAt == nil)
    }

    @Test("A malformed artifact leaves the card unappraised, and says what was wrong")
    func malformedArtifact() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        try "this is not json".write(
            to: fixture.artifactURL, atomically: true, encoding: .utf8)

        let report = await AppraisalHarvester(store: fixture.store).harvest(
            run: fixture.run, repo: fixture.repo, artifactURL: fixture.artifactURL
        )
        #expect(report.harvestSource == .none)
        #expect(report.dropped.contains { $0.contains("not valid JSON") })
        #expect(try await fixture.store.card(id: fixture.card.id)?.appraisedAt == nil)
    }

    @Test("The closing message is never read, even when it holds a perfect answer")
    func neverFallsBackToResultText() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        var run = fixture.run
        // `resultText` cannot be assigned directly — `SkillRun.setClosing(_:)`
        // is the one write path (`SkillRun.swift:252`) — but the point of this
        // test is unchanged: a run whose closing prose contains a plausible
        // appraisal must still yield nothing when no artifact was written.
        run.setClosing(
            ClosingRemark(
                text: """
                    I had a look. Here is the appraisal:

                    ```json
                    {"effort":"large","evidence":["Sources/Real.swift:1"]}
                    ```
                    """,
                source: .agent))
        try await fixture.store.saveRun(run)

        let report = await AppraisalHarvester(store: fixture.store).harvest(
            run: run, repo: fixture.repo, artifactURL: fixture.artifactURL
        )
        // The one difference from `ProposalHarvester`, asserted rather than
        // commented: a card left unappraised beats prose in a card field.
        #expect(report.harvestSource == .none)
        #expect(report.kept == 0)
        #expect(try await fixture.store.card(id: fixture.card.id)?.effort == nil)
    }

    @Test("\"appraised and found nothing\" is written, because it is a third state")
    func anEmptyAnswerIsStillAnAnswer() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        try """
        {"effort":"unstated","evidence":[]}
        """.write(to: fixture.artifactURL, atomically: true, encoding: .utf8)

        let report = await AppraisalHarvester(store: fixture.store).harvest(
            run: fixture.run, repo: fixture.repo, artifactURL: fixture.artifactURL
        )
        #expect(report.harvestSource == .artifact)
        #expect(report.kept == 1)

        let card = try #require(try await fixture.store.card(id: fixture.card.id))
        // `appraisedAt` is the third state. Without it, "nobody has appraised
        // this card" and "this card was appraised and carries no signal" are the
        // same value, and PR2's `CardValue` cannot tell `.neverAppraised` from
        // `.ungradeable`.
        #expect(card.appraisedAt != nil)
        #expect(card.effort == .unstated)
        #expect(card.evidence == [])
    }

    @Test("Decoder complaints reach the report rather than being swallowed")
    func droppedReasonsSurvive() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        try """
        {"effort":"small","evidence":["Sources/Real.swift",7]}
        """.write(to: fixture.artifactURL, atomically: true, encoding: .utf8)

        let report = await AppraisalHarvester(store: fixture.store).harvest(
            run: fixture.run, repo: fixture.repo, artifactURL: fixture.artifactURL
        )
        #expect(report.kept == 1)
        #expect(report.dropped.contains { $0.contains("Citation 2") })
    }

    @Test("A run with no card is reported, not crashed on")
    func aCardlessRunIsReported() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        try """
        {"effort":"small","evidence":[]}
        """.write(to: fixture.artifactURL, atomically: true, encoding: .utf8)

        var run = fixture.run
        run.cardID = nil
        let report = await AppraisalHarvester(store: fixture.store).harvest(
            run: run, repo: fixture.repo, artifactURL: fixture.artifactURL
        )
        #expect(report.harvestSource == .none)
        #expect(report.dropped.contains { $0.contains("no card") })
    }

    @Test("A card deleted mid-run is reported, not crashed on")
    func aDeletedCardIsReported() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        try """
        {"effort":"small","evidence":[]}
        """.write(to: fixture.artifactURL, atomically: true, encoding: .utf8)
        try await fixture.store.deleteCard(id: fixture.card.id)

        let report = await AppraisalHarvester(store: fixture.store).harvest(
            run: fixture.run, repo: fixture.repo, artifactURL: fixture.artifactURL
        )
        #expect(report.harvestSource == .none)
        #expect(report.dropped.contains { $0.contains("could not be found") })
    }
}
