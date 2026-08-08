import ElliotModel
import Foundation
import GRDB
import Testing

@testable import ElliotStore

// Lives apart from `BoardStoreTests` because it needs `import GRDB` to drive the
// migrator directly, and GRDB's `Column` collides with `ElliotModel.Column`
// there.

@Suite("Migrations")
struct MigrationsTests {

    /// The migration is only *additive* if a database that already holds rows
    /// survives it. Every other store test starts empty and runs v1 and v2 in
    /// one go, which cannot tell an additive migration from a destructive one.
    @Test("A v1 database with rows survives the v2 migration untouched")
    func v2LeavesV1DataIntact() throws {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue, upTo: "v1_initial")

        let id = UUID().uuidString.uppercased()
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO "repo"
                    ("id", "path", "nameWithOwner", "defaultBranch", "displayName",
                     "permissionMode", "extraAllowedTools", "isEnabled")
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    id, "/R/phmatray/private/Koine", "phmatray/Koine", "main", "Koine",
                    "bypassPermissions", "[]", true,
                ])
        }
        #expect(try queue.read { try Repo.fetchCount($0) } == 1)

        try Migrations.migrator.migrate(queue)

        let loaded = try queue.read { try Repo.fetchOne($0, key: id) }
        #expect(loaded?.nameWithOwner == "phmatray/Koine", "the v1 row is still there, unchanged")
        #expect(loaded?.displayName == "Koine")
        #expect(loaded?.visibility == nil, "the added column defaults to null on an existing row")
        #expect(try queue.read { try Int.fetchOne($0, sql: #"SELECT COUNT(*) FROM "setting""#) } == 0)
    }

    /// Every card already on a board must read as asking for no labels.
    ///
    /// `labels` is not optional, so an added column that defaulted to NULL — the
    /// shape v2's `visibility` above takes — would fail the *decode* of every
    /// existing row rather than the migration, which is a board that opens onto
    /// nothing and blames the store. The column is therefore NOT NULL with a
    /// `'[]'` default, and this is what says so about rows written before it
    /// existed.
    @Test("A card written before labels existed reads as asking for none")
    func labelsMigrationLeavesExistingCardsAskingForNothing() throws {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue, upTo: Self.migrationBeforeLabels)

        let repoID = UUID().uuidString.uppercased()
        let cardID = UUID().uuidString.uppercased()
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO "repo"
                    ("id", "path", "nameWithOwner", "defaultBranch", "displayName",
                     "permissionMode", "extraAllowedTools", "isEnabled")
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    repoID, "/R/phmatray/private/Koine", "phmatray/Koine", "main", "Koine",
                    "bypassPermissions", "[]", true,
                ])
            try db.execute(
                sql: """
                    INSERT INTO "card"
                    ("id", "repoID", "title", "body", "column", "orderIndex",
                     "columnEnteredAt", "createdAt", "updatedAt")
                    VALUES (?, ?, ?, '', 'backlog', 1024, ?, ?, ?)
                    """,
                arguments: [cardID, repoID, "Written before labels", then, then, then])
        }

        try Migrations.migrator.migrate(queue)

        let loaded = try queue.read { try Card.fetchOne($0, key: cardID) }
        #expect(loaded?.title == "Written before labels", "the pre-labels row is still there")
        #expect(loaded?.labels == [], "and it asks for no label, rather than failing to decode")
    }

    /// The order is the writer's and the column has to keep it: `--label` is
    /// repeatable, so the list is a sequence rather than a set, and a store that
    /// reordered it would reorder what a human sees on the card.
    @Test("Labels round-trip through the column in the order they were written")
    func labelsRoundTripInOrder() throws {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue)

        let repository = Repo(
            path: "/tmp/repo-\(UUID().uuidString)", nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot"
        )
        let card = Card(
            repoID: repository.id, title: "Bound the await",
            labels: ["documentation", "bug", "enhancement"],
            columnEnteredAt: then, createdAt: then, updatedAt: then
        )
        try queue.write { db in
            try repository.insert(db)
            try card.insert(db)
        }

        let loaded = try queue.read { try Card.fetchOne($0, key: card.id.uuidString.uppercased()) }
        #expect(loaded?.labels == ["documentation", "bug", "enhancement"])
    }

    /// Named once. When the next migration lands on top of this one, the two
    /// tests above must keep asking about the schema *before* labels rather than
    /// silently starting to test the newest thing instead.
    private static let migrationBeforeLabels = "v8_prStatus"
}

private let then = Date(timeIntervalSince1970: 1_700_000_000)
