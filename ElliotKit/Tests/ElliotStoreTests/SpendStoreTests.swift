import ElliotModel
import Foundation
import Testing

@testable import ElliotStore

@Suite("Spend — persistence and aggregate")
struct SpendStoreTests {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    /// `skillRun` has foreign keys onto `repo` and `card`, so a run cannot be
    /// inserted against bare UUIDs — the first draft of this suite tried, and
    /// SQLite refused it. One repo and one card per store, reused by every run.
    private func seeded() async throws -> (BoardStore, Repo, Card) {
        let store = try BoardStore.inMemory()
        let repo = Repo(
            path: "/tmp/Elliot", nameWithOwner: "phmatray/Elliot",
            defaultBranch: "main", displayName: "Elliot"
        )
        let card = Card(
            repoID: repo.id, title: "a card",
            columnEnteredAt: now, createdAt: now, updatedAt: now
        )
        try await store.saveRepo(repo)
        try await store.saveCard(card)
        return (store, repo, card)
    }

    private func run(
        _ repo: Repo, _ card: Card, cost: Double?, endedAt: Date?
    ) -> SkillRun {
        var run = SkillRun(
            cardID: card.id, repoID: repo.id, kind: .implementIssue, prompt: "x", cwd: "/tmp",
            logPath: "/tmp/a", stderrPath: "/tmp/b", createdAt: now
        )
        run.totalCostUSD = cost
        run.endedAt = endedAt
        run.state = endedAt == nil ? .running : .succeeded
        return run
    }

    @Test("An empty store has spent nothing, and knows it")
    func emptyIsComplete() async throws {
        let (store, _, _) = try await seeded()
        let spend = try await store.spend(since: now.addingTimeInterval(-86_400))
        #expect(spend == .nothing)
        #expect(spend.isComplete)
    }

    @Test("Costs are summed in the period")
    func sumsThePeriod() async throws {
        let (store, repo, card) = try await seeded()
        try await store.saveRun(run(repo, card, cost: 1.5, endedAt: now))
        try await store.saveRun(run(repo, card, cost: 2.25, endedAt: now.addingTimeInterval(60)))

        let spend = try await store.spend(since: now.addingTimeInterval(-60))
        #expect(spend.totalUSD == 3.75)
        #expect(spend.runs == 2)
        #expect(spend.isComplete)
    }

    @Test("A run that ended before the period is not counted")
    func periodIsRespected() async throws {
        let (store, repo, card) = try await seeded()
        try await store.saveRun(run(repo, card, cost: 99, endedAt: now.addingTimeInterval(-7_200)))
        try await store.saveRun(run(repo, card, cost: 1, endedAt: now))

        let spend = try await store.spend(since: now.addingTimeInterval(-3_600))
        #expect(spend.totalUSD == 1)
        #expect(spend.runs == 1)
    }

    @Test("A run still in flight contributes nothing — its cost does not exist yet")
    func unfinishedIsExcluded() async throws {
        let (store, repo, card) = try await seeded()
        try await store.saveRun(run(repo, card, cost: nil, endedAt: nil))
        try await store.saveRun(run(repo, card, cost: 4, endedAt: now))

        let spend = try await store.spend(since: now.addingTimeInterval(-60))
        #expect(spend.totalUSD == 4)
        // One row, not two: the running one is not "unknown cost", it is not
        // yet part of the answer at all.
        #expect(spend.runs == 1)
        #expect(spend.isComplete)
    }

    @Test("A finished run with no recorded cost is unknown, not free")
    func nullCostIsUnknown() async throws {
        // The distinction this whole type exists for. Reporting "$4.00" for a
        // set where one run's cost was never recorded understates the bill and
        // gives the reader no way to tell.
        let (store, repo, card) = try await seeded()
        try await store.saveRun(run(repo, card, cost: 4, endedAt: now))
        try await store.saveRun(run(repo, card, cost: nil, endedAt: now))

        let spend = try await store.spend(since: now.addingTimeInterval(-60))
        #expect(spend.totalUSD == 4)
        #expect(spend.runs == 2)
        #expect(spend.unknownCost == 1)
        #expect(!spend.isComplete)
    }

    @Test("The ceiling round-trips and does not collide with the other settings")
    func ceilingPersists() async throws {
        let (store, _, _) = try await seeded()
        #expect(try await store.spendCeiling() == nil)

        let ceiling = SpendCeiling(perRunUSD: 3, perDayUSD: 25)
        try await store.saveSpendCeiling(ceiling)
        try await store.saveLimits(SchedulerLimits(maxConcurrent: 5, maxConcurrentAnalyses: 2))

        #expect(try await store.spendCeiling() == ceiling)
        #expect(try await store.limits()?.maxConcurrent == 5)
    }
}
