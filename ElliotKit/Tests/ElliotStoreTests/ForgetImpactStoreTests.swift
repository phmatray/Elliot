import ElliotModel
import Foundation
import Testing

@testable import ElliotStore

/// The counts the confirmation promises, measured against the schema that
/// actually cascades. The third test is the load-bearing one: it proves the
/// sentence is true, rather than merely well-worded.
@Suite("Forget impact, counted")
struct ForgetImpactStoreTests {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func seed(_ store: BoardStore, name: String) async throws -> Repo {
        var repo = Repo(path: "/tmp/\(name)", nameWithOwner: "phmatray/\(name)", displayName: name)
        repo.isEnabled = true
        try await store.saveRepo(repo)

        for (index, title) in ["one", "two"].enumerated() {
            let card = Card(
                repoID: repo.id, title: title, column: .backlog, orderIndex: Double(index),
                columnEnteredAt: epoch, createdAt: epoch, updatedAt: epoch)
            try await store.saveCard(card)
            try await store.saveRun(SkillRun(
                cardID: card.id, repoID: repo.id, kind: .createIssue,
                prompt: "/create-issue", cwd: "/tmp", state: .succeeded, startedAt: epoch,
                logPath: "/tmp/log.ndjson", stderrPath: "/tmp/log.stderr", createdAt: epoch))
        }

        // The analysis row first: `StoryProposal.analysisID` is a foreign key,
        // so a proposal hung off a bare `UUID()` is rejected by the schema.
        let analysisID = UUID()
        try await store.saveAnalysis(Analysis(
            id: analysisID, repoID: repo.id, angles: [.bugs],
            maxStoriesPerAngle: 5, createdAt: epoch))
        try await store.saveProposal(StoryProposal(
            analysisID: analysisID, runID: UUID(), repoID: repo.id, angle: .bugs,
            title: "A finding",
            story: UserStory(role: "developer", want: "a count", benefit: "an informed click"),
            rationale: "seeded", createdAt: epoch))
        return repo
    }

    @Test("Counts every kind the cascade takes")
    func countsEveryKind() async throws {
        let store = try BoardStore.inMemory()
        let repo = try await seed(store, name: "Elliot")

        let impact = try await store.forgetImpact(repoID: repo.id)
        #expect(impact.cards == 2)
        #expect(impact.runs == 2)
        #expect(impact.analyses == 1)
        #expect(impact.proposals == 1)
        #expect(!impact.isEmpty)
    }

    @Test("A second repository's rows are not counted")
    func scopedToOneRepo() async throws {
        // With rows in only one repository, a dropped `repoID` filter counts the
        // same number and the test sees nothing — the exact drift
        // `OfflineParityTests` records having measured elsewhere.
        let store = try BoardStore.inMemory()
        let mine = try await seed(store, name: "Elliot")
        _ = try await seed(store, name: "Koine")

        let impact = try await store.forgetImpact(repoID: mine.id)
        #expect(impact.cards == 2)
        #expect(impact.runs == 2)
        #expect(impact.analyses == 1)
        #expect(impact.proposals == 1)
    }

    @Test("Every counted row is gone after the delete — the sentence is true")
    func theCascadeMatchesTheCount() async throws {
        let store = try BoardStore.inMemory()
        let repo = try await seed(store, name: "Elliot")
        let other = try await seed(store, name: "Koine")

        #expect(try await store.forgetImpact(repoID: repo.id).isEmpty == false)
        try await store.deleteRepo(id: repo.id)

        #expect(try await store.forgetImpact(repoID: repo.id).isEmpty)
        // And the neighbour is untouched: a cascade wider than the sentence
        // would be a worse defect than a sentence wider than the cascade.
        #expect(try await store.forgetImpact(repoID: other.id).cards == 2)
    }

    @Test("A repository with nothing on the board counts zero, and does not throw")
    func emptyRepo() async throws {
        let store = try BoardStore.inMemory()
        var repo = Repo(path: "/tmp/New", nameWithOwner: "phmatray/New", displayName: "New")
        repo.isEnabled = true
        try await store.saveRepo(repo)

        #expect(try await store.forgetImpact(repoID: repo.id).isEmpty)
    }
}
