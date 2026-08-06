import ElliotModel
import Foundation
import Testing

@testable import ElliotStore

/// The shallow, board-wide reads an overview needs.
///
/// `runs(cardID:)` loads one selected card deeply and is right to; these are the
/// second path, because a page that asks a question per row cannot exist on a
/// board of three hundred repositories.
@Suite("Batch run reads")
struct BatchRunReadTests {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func seeded() async throws -> (BoardStore, Repo, Card) {
        let store = try BoardStore.inMemory()
        let repo = Repo(
            path: "/tmp/Elliot", nameWithOwner: "phmatray/Elliot",
            defaultBranch: "main", displayName: "Elliot"
        )
        let card = Card(
            repoID: repo.id, title: "c", columnEnteredAt: now, createdAt: now, updatedAt: now
        )
        try await store.saveRepo(repo)
        try await store.saveCard(card)
        return (store, repo, card)
    }

    @discardableResult
    private func run(
        _ store: BoardStore, _ repo: Repo, _ card: Card, createdAt: Date
    ) async throws -> SkillRun {
        let run = SkillRun(
            cardID: card.id, repoID: repo.id, kind: .implementIssue, prompt: "x", cwd: "/tmp",
            logPath: "/tmp/a", stderrPath: "/tmp/b", createdAt: createdAt
        )
        try await store.saveRun(run)
        return run
    }

    @Test("An empty board has no recent runs, which is not an error")
    func emptyIsEmpty() async throws {
        let (store, _, _) = try await seeded()
        #expect(try await store.recentRuns().isEmpty)
    }

    @Test("Recent runs come back newest first")
    func newestFirst() async throws {
        let (store, repo, card) = try await seeded()
        let old = try await run(store, repo, card, createdAt: now.addingTimeInterval(-3_600))
        let new = try await run(store, repo, card, createdAt: now)

        #expect(try await store.recentRuns().map(\.id) == [new.id, old.id])
    }

    @Test("The limit is a limit, and takes the newest")
    func limitTakesTheNewest() async throws {
        // The boundary that matters: a limit that silently returned the *oldest*
        // rows would make an overview look permanently stale rather than empty.
        let (store, repo, card) = try await seeded()
        for offset in 0..<5 {
            try await run(store, repo, card, createdAt: now.addingTimeInterval(Double(offset)))
        }
        let rows = try await store.recentRuns(limit: 2)
        #expect(rows.count == 2)
        #expect(rows[0].createdAt > rows[1].createdAt)
        #expect(rows[0].createdAt == now.addingTimeInterval(4))
    }

    @Test("One repository's runs are its own, and only since the date asked for")
    func perRepoAndPeriod() async throws {
        let (store, repo, card) = try await seeded()
        let other = Repo(
            path: "/tmp/Lyrics", nameWithOwner: "phmatray/Lyrics",
            defaultBranch: "main", displayName: "Lyrics"
        )
        let otherCard = Card(
            repoID: other.id, title: "c", columnEnteredAt: now, createdAt: now, updatedAt: now
        )
        try await store.saveRepo(other)
        try await store.saveCard(otherCard)

        try await run(store, repo, card, createdAt: now.addingTimeInterval(-7_200))
        let recent = try await run(store, repo, card, createdAt: now)
        try await run(store, other, otherCard, createdAt: now)

        let rows = try await store.runs(repoID: repo.id, since: now.addingTimeInterval(-3_600))
        #expect(rows.map(\.id) == [recent.id])
    }

    @Test("Loading the board-wide list does not disturb the per-card one")
    func perCardIsUntouched() async throws {
        // `refreshRuns(cardID:)` is deliberately left as it is; this proves the
        // two paths coexist rather than one having quietly replaced the other.
        let (store, repo, card) = try await seeded()
        try await run(store, repo, card, createdAt: now)

        #expect(try await store.recentRuns().count == 1)
        #expect(try await store.runs(cardID: card.id).count == 1)
    }
}
