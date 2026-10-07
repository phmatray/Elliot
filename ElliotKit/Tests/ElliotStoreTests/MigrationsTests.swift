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

    /// Every run already on a board must read back naming no predecessor.
    ///
    /// Deliberately the same two-claims-in-one-window shape as
    /// `runsPredatingTheSourceColumnAreNotAttributed` above, and against the
    /// same table — v11 and v13 both add a column to `skillRun` for the same
    /// `openReadOnly` reason, so a second set of scaffolding to say it would be
    /// a second thing to keep true. First the *absent column* case, which is
    /// what `openReadOnly` serves between a new bundle landing and the app next
    /// launching: the row is fetched with a record type that knows a column the
    /// file does not have. `resumedFrom` is an `Optional`, so the synthesised
    /// decoder calls `decodeIfPresent` and it reads as nil; a non-optional
    /// `UUID` would throw `keyNotFound` on **every run ever recorded**, and
    /// nothing in the compiler says so. Then the migrated case, where the
    /// column exists and is NULL.
    ///
    /// ⛔ NULL must stay NULL — there is no backfill and there can be no
    /// honest one. Nothing before this build ever forked a session, so nil is
    /// the truth about these rows rather than a default standing in for an
    /// unknown.
    @Test("A run written before the resume column names no predecessor")
    func runsPredatingResumedFromHaveNoPredecessor() throws {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue, upTo: Self.migrationBeforeResumedFrom)

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
                    VALUES (?, ?, 'Written before the resume column', '', 'todo', 1024, ?, ?, ?)
                    """,
                arguments: [cardID, repoID, then, then, then])
            try db.execute(
                sql: """
                    INSERT INTO "skillRun"
                    ("id", "cardID", "repoID", "kind", "prompt", "argv", "cwd", "state",
                     "logPath", "stderrPath", "permissionDenials", "createdAt")
                    VALUES (?, ?, ?, 'createIssue', '/x', '[]', '/tmp', 'succeeded',
                            '/tmp/a.ndjson', '/tmp/a.stderr', '[]', ?)
                    """,
                arguments: [runID, cardID, repoID, then])
        }

        // The fixture is genuinely a pre-v13 database, or everything below
        // upgrades a schema that was already current and measures nothing.
        let columns = try queue.read { db in try db.columns(in: "skillRun").map(\.name) }
        #expect(!columns.contains("resumedFrom"), "the fixture is not actually a pre-v13 database")

        // The window `openReadOnly` exists to keep working: the record type
        // knows a column this file does not have.
        let missing = try queue.read { try SkillRun.fetchOne($0, key: runID) }
        let beforeMigrating = try #require(missing, "a pre-v13 run failed to decode at all")
        #expect(beforeMigrating.resumedFrom == nil)

        try Migrations.migrator.migrate(queue)

        let loaded = try #require(try queue.read { try SkillRun.fetchOne($0, key: runID) })
        #expect(loaded.cwd == "/tmp", "the pre-v13 row is still there, unchanged")
        #expect(
            loaded.resumedFrom == nil,
            "the added column reads as absent, not as a predecessor the migration invented")
    }

    /// A predecessor recorded today survives the round trip, so the test above
    /// is not passing because the column is never populated at all.
    ///
    /// It also says the column is *live* rather than merely created: an
    /// `ALTER TABLE` that added it under another name, or a record type that
    /// never encoded it, would leave the test above green and this one red.
    @Test("A predecessor recorded today round-trips through the column")
    func resumedFromRoundTrips() throws {
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
        let first = SkillRun.card(
            cardID: card.id, repoID: repository.id, kind: .createIssue, prompt: "/x",
            cwd: "/tmp", logPath: "/tmp/a.ndjson", stderrPath: "/tmp/a.stderr", createdAt: then
        )
        let forked = SkillRun.card(
            cardID: card.id, repoID: repository.id, kind: .createIssue, prompt: "/x",
            cwd: "/tmp", resumedFrom: first.id,
            logPath: "/tmp/b.ndjson", stderrPath: "/tmp/b.stderr", createdAt: then
        )
        try queue.write { db in
            try repository.insert(db)
            try card.insert(db)
            try first.insert(db)
            try forked.insert(db)
        }

        let loaded = try queue.read { try SkillRun.fetchOne($0, key: forked.id.uuidString.uppercased()) }
        #expect(loaded?.resumedFrom == first.id)
        // The first attempt of a chain has no predecessor of its own, and that
        // is a different fact from "this build cannot store one".
        let origin = try queue.read { try SkillRun.fetchOne($0, key: first.id.uuidString.uppercased()) }
        #expect(origin?.resumedFrom == nil)
    }

    /// Every run already on a board must read back naming no agent session and
    /// no stop reason.
    ///
    /// The same two-claims-in-one-window shape as the two tests above, against
    /// the same table and for the same reason — v11, v13 and v17 all add a
    /// nullable column to `skillRun` so `BoardStore.openReadOnly` keeps serving
    /// a helper that is ahead of the file. First the *absent column* case: the
    /// row is fetched with a record type that knows two columns the file does
    /// not have. Both are `Optional`, so the synthesised decoder calls
    /// `decodeIfPresent` and they read as nil; a non-optional `String` would
    /// throw `keyNotFound` on **every run ever recorded**, and a default value
    /// on the property would not change that. Then the migrated case, where the
    /// columns exist and are NULL.
    ///
    /// ⛔ NULL must stay NULL — there is no backfill and there can be no honest
    /// one. Nothing before this build ever ran under ACP, so nil is the truth
    /// about these rows rather than a default standing in for an unknown.
    /// Inferring a session from `argv` or a stop reason from the exit code would
    /// write a guess where nothing afterwards could tell it from a measurement.
    @Test("runs recorded before v17 have no agent session and no stop reason")
    func runsPredatingV17ReadNil() throws {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue, upTo: Self.migrationBeforeACPSession)

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
                    VALUES (?, ?, 'Written before ACP', '', 'todo', 1024, ?, ?, ?)
                    """,
                arguments: [cardID, repoID, then, then, then])
            try db.execute(
                sql: """
                    INSERT INTO "skillRun"
                    ("id", "cardID", "repoID", "kind", "prompt", "argv", "cwd", "state",
                     "logPath", "stderrPath", "permissionDenials", "createdAt")
                    VALUES (?, ?, ?, 'createIssue', '/x', '[]', '/tmp', 'succeeded',
                            '/tmp/a.ndjson', '/tmp/a.stderr', '[]', ?)
                    """,
                arguments: [runID, cardID, repoID, then])
        }

        // The fixture is genuinely a pre-v17 database, or everything below
        // upgrades a schema that was already current and measures nothing.
        let columns = try queue.read { db in try db.columns(in: "skillRun").map(\.name) }
        #expect(!columns.contains("agentSessionID"), "the fixture is not actually a pre-v17 database")
        #expect(!columns.contains("stopReason"), "the fixture is not actually a pre-v17 database")

        // The window `openReadOnly` exists to keep working: the record type
        // knows two columns this file does not have.
        let missing = try queue.read { try SkillRun.fetchOne($0, key: runID) }
        let beforeMigrating = try #require(missing, "a pre-v17 run failed to decode at all")
        #expect(beforeMigrating.agentSessionID == nil)
        #expect(beforeMigrating.stopReason == nil)

        try Migrations.migrator.migrate(queue)

        let loaded = try #require(try queue.read { try SkillRun.fetchOne($0, key: runID) })
        #expect(loaded.cwd == "/tmp", "the pre-v17 row is still there, unchanged")
        #expect(
            loaded.agentSessionID == nil,
            "the added column reads as absent, not as a session the migration invented")
        #expect(
            loaded.stopReason == nil,
            "the added column reads as absent, not as an ending the migration invented")
    }

    /// A session and a stop reason recorded today survive the round trip, so the
    /// test above is not passing because the columns are never populated at all.
    ///
    /// Built through the designated initialiser rather than `SkillRun.card`,
    /// because the initialiser is where the two parameters were added and the
    /// factory deliberately does not forward them — the writer is Task 15's
    /// `finish`. It also says the columns are *live* rather than merely created:
    /// an `ALTER TABLE` that added them under another name, or a record type
    /// that never encoded them, would leave the test above green and this one
    /// red.
    @Test("an agent session id and a stop reason round-trip")
    func acpSessionRoundTrips() throws {
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
        let underACP = SkillRun(
            cardID: card.id, repoID: repository.id, kind: .createIssue, prompt: "/x",
            cwd: "/tmp", logPath: "/tmp/a.ndjson", stderrPath: "/tmp/a.stderr",
            agentSessionID: "sess_01JQZ8H4", stopReason: "end_turn", createdAt: then
        )
        // A run whose response never arrived — the shape a run that died
        // mid-turn leaves behind, and a different fact from "this build cannot
        // store one".
        let diedMidTurn = SkillRun.card(
            cardID: card.id, repoID: repository.id, kind: .createIssue, prompt: "/x",
            cwd: "/tmp", logPath: "/tmp/b.ndjson", stderrPath: "/tmp/b.stderr", createdAt: then
        )
        try queue.write { db in
            try repository.insert(db)
            try card.insert(db)
            try underACP.insert(db)
            try diedMidTurn.insert(db)
        }

        let loaded = try queue.read { try SkillRun.fetchOne($0, key: underACP.id.uuidString.uppercased()) }
        #expect(loaded?.agentSessionID == "sess_01JQZ8H4")
        #expect(loaded?.stopReason == "end_turn")
        let orphan = try queue.read { try SkillRun.fetchOne($0, key: diedMidTurn.id.uuidString.uppercased()) }
        #expect(orphan?.agentSessionID == nil)
        #expect(orphan?.stopReason == nil)
    }

    /// Named once. When the next migration lands on top of this one, the two
    /// tests above must keep asking about the schema *before* labels rather than
    /// silently starting to test the newest thing instead.
    private static let migrationBeforeLabels = "v8_prStatus"

    /// The same, for the run-source column. Named for the same reason: the
    /// point is the schema one step behind it, not whatever is newest.
    private static let migrationBeforeResultSource = "v10_repoPreflight"

    /// And for the resume column. Third of the same shape, which is what says
    /// this is the file's convention rather than three coincidences.
    private static let migrationBeforeResumedFrom = "v12_cardAppraisal"

    /// And for the ACP session columns. `upTo:` is inclusive, so this names the
    /// migration that must have *run*, leaving the schema one step behind v17.
    private static let migrationBeforeACPSession = "v16_autoDev"
}

private let then = Date(timeIntervalSince1970: 1_700_000_000)
