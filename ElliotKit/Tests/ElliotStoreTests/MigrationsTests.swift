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
}
