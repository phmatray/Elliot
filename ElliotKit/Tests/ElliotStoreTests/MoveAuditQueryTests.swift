import ElliotModel
import Foundation
import Testing

@testable import ElliotStore

/// Reading the board's own account of why a card moved.
///
/// The audit trail is the only place that records *why*, which is what makes it
/// the right source for "the board moved a card by itself" (#36). Watching the
/// card table instead would see a column change and have to guess whether a
/// person or `PRWatcher` caused it — and that guess is exactly how someone's own
/// drag becomes a notification telling them what they just did.
@Suite("Move audit by time")
struct MoveAuditQueryTests {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func seed() async throws -> (BoardStore, Repo, Card) {
        let store = try BoardStore.inMemory()
        let repo = Repo(
            id: UUID(), path: "/tmp/elliot", nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot", isEnabled: true
        )
        let card = Card(
            id: UUID(), repoID: repo.id, title: "Stream the run log", column: .todo,
            orderIndex: 1, columnEnteredAt: epoch, createdAt: epoch, updatedAt: epoch
        )
        try await store.saveRepo(repo)
        try await store.saveCard(card)
        return (store, repo, card)
    }

    private func audit(
        _ card: Card, _ origin: MoveOrigin, at: Date, from: Column = .todo, to: Column = .inProgress
    ) -> MoveAudit {
        MoveAudit(cardID: card.id, from: from, to: to, origin: origin, at: at)
    }

    @Test("Audits before the watermark are excluded, and the rest arrive oldest first")
    func sinceIsExclusiveAndOrderIsAscending() async throws {
        let (store, _, card) = try await seed()
        let t0 = epoch, t1 = epoch.addingTimeInterval(60), t2 = epoch.addingTimeInterval(120)

        // Written out of order on purpose: the order that matters is `at`, not
        // insertion, and a follower that trusted insertion order would replay
        // an audit that arrived late.
        try await store.insertMoveAudit(audit(card, .userDrag, at: t2))
        try await store.insertMoveAudit(audit(card, .system(reason: .prBecameReady), at: t0))
        try await store.insertMoveAudit(audit(card, .mcp(client: "claude-code"), at: t1))

        let since = try await store.moveAudits(since: t0)
        // `t0` itself is excluded — handing back the `at` you last handled must
        // not replay it, or every poll re-notifies its own last row.
        #expect(since.count == 2)
        #expect(since.map(\.at) == [t1, t2])

        let all = try await store.moveAudits(since: t0.addingTimeInterval(-1))
        #expect(all.map(\.at) == [t0, t1, t2], "ascending is what lets a follower resume")
    }

    @Test("The origin survives the round trip, reason and all")
    func originRoundTrips() async throws {
        let (store, _, card) = try await seed()
        // Every origin, because the notification policy branches on all three
        // and a `.system` that came back as `.userDrag` would silence exactly
        // the events #36 exists to surface.
        let origins: [MoveOrigin] = [
            .userDrag,
            .mcp(client: "claude-code"),
            .system(reason: .prBecameReady),
            .system(reason: .prMergedExternally),
            .system(reason: .reconciliation),
            .system(reason: .githubImport),
        ]
        for (index, origin) in origins.enumerated() {
            try await store.insertMoveAudit(
                audit(card, origin, at: epoch.addingTimeInterval(Double(index + 1)))
            )
        }

        let read = try await store.moveAudits(since: epoch)
        #expect(read.map(\.origin) == origins)
    }

    @Test("A limit takes the oldest unseen, not the newest")
    func limitKeepsTheOldest() async throws {
        // The direction that matters. Taking the newest `limit` would silently
        // drop the middle of a busy interval, and a follower would never learn
        // it had missed anything.
        let (store, _, card) = try await seed()
        for index in 1...10 {
            try await store.insertMoveAudit(
                audit(card, .system(reason: .prBecameReady), at: epoch.addingTimeInterval(Double(index)))
            )
        }

        let page = try await store.moveAudits(since: epoch, limit: 3)
        #expect(page.count == 3)
        #expect(page.map(\.at) == (1...3).map { epoch.addingTimeInterval(Double($0)) })
    }

    @Test("An empty trail is an empty answer, not a failure")
    func emptyTrail() async throws {
        let (store, _, _) = try await seed()
        #expect(try await store.moveAudits(since: epoch).isEmpty)
    }

    @Test("The index the query needs exists after migration")
    func indexExists() async throws {
        // v6 is index-only, so nothing about the data proves it ran. Asserting
        // the index by name is the only way this migration can be shown to have
        // done anything at all.
        let (store, _, _) = try await seed()
        let names = try await store.indexNames(on: "moveAudit")
        #expect(names.contains("moveAudit_on_at"), "saw \(names.sorted())")
        // The one that was already there, so appending v6 is proved additive.
        #expect(names.contains("moveAudit_on_card_at"))
    }
}
