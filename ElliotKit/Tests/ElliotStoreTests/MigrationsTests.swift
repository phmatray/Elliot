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

    /// Every run already on a board must read back saying nothing about where
    /// its text came from.
    ///
    /// Two claims in one test, because they are one window. First the *absent
    /// column* case, which is what `openReadOnly` serves between a new bundle
    /// landing and the app next launching: the row is fetched with a record
    /// type that knows a column the file does not have. `resultSource` is an
    /// `Optional`, so the synthesised decoder calls `decodeIfPresent` and it
    /// reads as nil — a non-optional would throw `keyNotFound` on **every run
    /// ever recorded**, which is the trap `labels` had to be given
    /// `@DefaultsToEmpty` for. Then the migrated case, where the column exists
    /// and is NULL.
    ///
    /// ⛔ NULL must stay NULL. Defaulting these rows to `agent` — or inferring
    /// a source from `numTurns`, the state, the exit code — would write a guess
    /// into the database where nothing afterwards could tell it from a
    /// measurement, and guessing is the whole of what the column exists to stop
    /// (#288).
    @Test("A run written before the source column reads as unattributed, not as the agent's")
    func runsPredatingTheSourceColumnAreNotAttributed() throws {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue, upTo: Self.migrationBeforeResultSource)

        let repoID = UUID().uuidString.uppercased()
        let cardID = UUID().uuidString.uppercased()
        let runID = UUID().uuidString.uppercased()
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
                    VALUES (?, ?, 'Written before the source', '', 'todo', 1024, ?, ?, ?)
                    """,
                arguments: [cardID, repoID, then, then, then])
            try db.execute(
                sql: """
                    INSERT INTO "skillRun"
                    ("id", "cardID", "repoID", "kind", "prompt", "argv", "cwd", "state",
                     "logPath", "stderrPath", "resultText", "permissionDenials", "createdAt")
                    VALUES (?, ?, ?, 'createIssue', '/x', '[]', '/tmp', 'failed',
                            '/tmp/a.ndjson', '/tmp/a.stderr', ?, '[]', ?)
                    """,
                arguments: [runID, cardID, repoID, "zsh: command not found: claude", then])
        }

        // The window `openReadOnly` exists to keep working: the column is
        // genuinely not there yet.
        let missing = try queue.read { try SkillRun.fetchOne($0, key: runID) }
        let beforeMigrating = try #require(missing, "a pre-v11 run failed to decode at all")
        #expect(beforeMigrating.resultText == "zsh: command not found: claude")
        #expect(beforeMigrating.resultSource == nil)

        try Migrations.migrator.migrate(queue)

        let loaded = try #require(try queue.read { try SkillRun.fetchOne($0, key: runID) })
        #expect(loaded.resultText == "zsh: command not found: claude")
        #expect(loaded.resultSource == nil, "the migration invented a source for history")
        // This row really does hold stderr, and the board still may not say so:
        // nothing recorded it, and a caption is not the place to start guessing.
        #expect(loaded.closing?.caption == "it said")
        #expect(loaded.closing?.isHearsay == true)
    }

    /// A source written today survives the round trip, so the test above is not
    /// passing because the column is never populated at all.
    @Test("A source recorded today round-trips through the column")
    func resultSourceRoundTrips() throws {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue)

        let repository = Repo(
            path: "/tmp/repo-\(UUID().uuidString)", nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot"
        )
        let card = Card(
            repoID: repository.id, title: "Anything",
            columnEnteredAt: then, createdAt: then, updatedAt: then
        )
        let run = SkillRun.card(
            cardID: card.id, repoID: repository.id, kind: .createIssue, prompt: "/x",
            cwd: "/tmp", logPath: "/tmp/a.ndjson", stderrPath: "/tmp/a.stderr",
            closing: ClosingRemark(text: "zsh: command not found: claude", source: .stderr),
            createdAt: then
        )
        try queue.write { db in
            try repository.insert(db)
            try card.insert(db)
            try run.insert(db)
        }

        let loaded = try queue.read { try SkillRun.fetchOne($0, key: run.id.uuidString.uppercased()) }
        #expect(loaded?.resultSource == .stderr)
        #expect(loaded?.closing?.caption == "stderr")
        #expect(loaded?.closing?.isHearsay == false)
    }

    /// Named once. When the next migration lands on top of this one, the two
    /// tests above must keep asking about the schema *before* labels rather than
    /// silently starting to test the newest thing instead.
    private static let migrationBeforeLabels = "v8_prStatus"

    /// The same, for the run-source column. Named for the same reason: the
    /// point is the schema one step behind it, not whatever is newest.
    private static let migrationBeforeResultSource = "v10_repoPreflight"
}

private let then = Date(timeIntervalSince1970: 1_700_000_000)
