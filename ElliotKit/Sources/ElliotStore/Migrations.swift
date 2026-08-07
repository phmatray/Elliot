import Foundation
import GRDB

enum Migrations {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_initial", migrate: v1Initial)

        // Additive only: v1 databases in the field must keep their rows.
        migrator.registerMigration("v2_repositoryLayout") { db in
            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
            try db.alter(table: "repo") { t in
                t.add(column: "visibility", .text)
            }
        }

        // v3 rather than a second v2: `v2_repositoryLayout` above has shipped on
        // `main`, and a migration's name is its identity in `grdb_migrations`.
        // Renaming a shipped one makes every database in the field try to run it
        // again; this one has shipped nowhere, so it is the one that moves.
        migrator.registerMigration("v3_cardIdempotencyKey") { db in
            try db.alter(table: "card") { t in
                t.add(column: "idempotencyKey", .text)
            }
            // The retry of a create that timed out on the way back may reach a
            // different app process than the first attempt, so the "only one
            // card" guarantee has to be in the schema. SQLite counts NULLs as
            // distinct here, which is what lets every keyless card — all of the
            // ones made in the UI — share the column without colliding.
            //
            // Unique on the key alone, not on `(repoID, idempotencyKey)`: the
            // lookup names only the key, and a key that could repeat across
            // repositories would answer with an arbitrary one of them.
            try db.create(
                index: "card_on_idempotencyKey",
                on: "card",
                columns: ["idempotencyKey"],
                unique: true
            )
        }

        // v4 for the same reason v3 is v3: this one was written as `v2_analysis`
        // on a branch that had not landed, and `v2_repositoryLayout` reached
        // `main` first. The unshipped name is the one that moves.
        //
        // Deferred because skillRun is rebuilt: its rows reference card and repo
        // while the table is briefly named skillRun_old.
        migrator.registerMigration("v4_analysis", foreignKeyChecks: .deferred, migrate: v4Analysis)

        // v5, though the issue that asked for it called it v2: v2, v3 and v4 all
        // reached `main` first, and a migration's name is its identity in
        // `grdb_migrations`. Numbering it v2 would mean a second, different
        // migration under a name every database in the field has already run.
        migrator.registerMigration("v5_githubImport") { db in
            // Ownership of an issue or a pull request is exclusive. Enforced by
            // the database and not only by the planner, because an idempotent
            // refresh is the whole point of the import and a duplicate card is
            // indistinguishable from real work.
            //
            // Partial: a card that has filed nothing has NULL in both columns,
            // and SQLite does not collide NULLs in a unique index.
            try db.execute(sql: """
                CREATE UNIQUE INDEX card_on_repo_issue ON card(repoID, issueNumber)
                WHERE issueNumber IS NOT NULL
                """)
            try db.execute(sql: """
                CREATE UNIQUE INDEX card_on_repo_pr ON card(repoID, prNumber)
                WHERE prNumber IS NOT NULL
                """)

            // A card the user deleted must not come back on the next refresh.
            // Keyed by number rather than card id: the card is gone.
            try db.create(table: "dismissedExternal") { t in
                t.column("repoID", .text).notNull()
                    .references("repo", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("number", .integer).notNull()
                t.column("dismissedAt", .datetime).notNull()
                t.primaryKey(["repoID", "kind", "number"])
            }
        }

        // v6, appended rather than renumbered: v5 has shipped, and a migration's
        // name is its identity in `grdb_migrations`. The issue asked for this as
        // "v5_moveAuditAtIndex", which was taken while it sat in the backlog.
        //
        // Index only, no column changes. `moveAudit_on_card_at` covers "this
        // card's history"; a follower asking "everything since this moment"
        // across every card has no leading column to use and scans the table.
        // That is cheap today and grows with the board, and the follower is a
        // notification poller that runs for as long as the app is open.
        migrator.registerMigration("v6_moveAuditAtIndex") { db in
            try db.create(index: "moveAudit_on_at", on: "moveAudit", columns: ["at"])
        }

        // v7, additive: a card can now say which analysis lens found it.
        //
        // v7 and not v6: this was written as v6 while `v6_moveAuditAtIndex`
        // sat unmerged, and that one reached `main` first. A migration's
        // name is its identity in `grdb_migrations`, so the unshipped one is
        // the one that moves — the same trade v3, v4 and v5 each made above.
        //
        // The backfill is not a guess. `storyProposal` has recorded both the
        // lens and the id of the card it produced since v4, so every card that
        // came from an analysis already carries the answer one join away —
        // without this, the feature would ship empty on every existing board
        // and look like a feature that does not work.
        migrator.registerMigration("v7_cardAngle") { db in
            try db.alter(table: "card") { t in
                t.add(column: "angle", .text)
            }
            try db.execute(sql: Migrations.backfillCardAnglesSQL)
        }

        return migrator
    }

    // MARK: - Migrations that ran under a name this build no longer registers

    /// A migration that reached a database under one name and this build under
    /// another, together with the schema that proves it actually ran.
    struct RenamedMigration {
        let legacy: String
        let current: String
        /// Read against the live schema rather than trusted from the ledger.
        let ranAlready: @Sendable (Database) throws -> Bool
    }

    /// Renames of unshipped migrations, and the reason this list exists.
    ///
    /// Every comment above marked "vN rather than vN-1" describes the same
    /// trade: two branches claimed a number, the one that reached `main` first
    /// kept it, and the other was renamed. That trade is right for databases in
    /// the field — they only ever saw the shipped name — but it is wrong for
    /// every machine that ran the losing branch before it landed, because GRDB
    /// identifies a migration by its **name**. Those databases hold the new
    /// schema under the old name, so the renamed migration looks unapplied and
    /// runs a second time over tables it already made.
    ///
    /// Measured, not hypothesised: a store whose ledger read `v1_initial,
    /// v2_analysis, v2_repositoryLayout, v3_cardIdempotencyKey` over a schema
    /// that was already v4's in every column, index and check — the app refused
    /// to start with `SQLite error 1: table "analysis" already exists`, and
    /// `openReadOnly` called the same file `schemaTooNew`.
    ///
    /// Adopting the rename means recording the current name and dropping the
    /// old one, which leaves a file indistinguishable from one that had run the
    /// shipped name all along. Nothing downstream then has to know either name.
    ///
    /// The list has one entry because one rename is known to have escaped onto a
    /// machine. The four others — v3, v5, v6 and v7 — were renamed the same way,
    /// so if one of those old names ever turns up in a ledger, it belongs here
    /// with the schema check that proves it: **the name is the symptom, the
    /// schema is the evidence.**
    static let renamedMigrations: [RenamedMigration] = [
        RenamedMigration(legacy: "v2_analysis", current: "v4_analysis") { db in
            // Both halves of `v4Analysis`, not just the table it fails on: it
            // creates `analysis` and then rebuilds `skillRun` to reference it.
            try db.tableExists("analysis")
                && db.columns(in: "skillRun").contains { $0.name == "analysisID" }
        }
    ]

    /// Records a renamed migration under the name this build registers, so the
    /// migrator does not run it a second time.
    ///
    /// Deliberately not a migration itself. A migration would have to be
    /// registered ahead of the one it protects, where it would run on every
    /// fresh database as a no-op and read as schema work — and it edits the
    /// ledger, which is the one table migrations are not about. It runs before
    /// `migrate` instead, from the app, which is the sole writer.
    static func adoptRenamedMigrations(in writer: any DatabaseWriter) throws {
        try writer.write { db in
            // A database that has never been migrated has no ledger to read, and
            // nothing to adopt. Creating one here would be inventing history.
            guard try db.tableExists("grdb_migrations") else { return }
            let applied = Set(
                try String.fetchAll(db, sql: #"SELECT "identifier" FROM "grdb_migrations""#)
            )
            for rename in renamedMigrations {
                guard applied.contains(rename.legacy),
                    !applied.contains(rename.current)
                else { continue }
                // A ledger can name a migration whose work is not in the schema —
                // a hand-edited file, a partial restore. Marking that applied
                // would skip the migration for good and fail much later, much
                // further from the cause, so it declines and lets it run.
                guard try rename.ranAlready(db) else { continue }
                try db.execute(
                    sql: #"INSERT INTO "grdb_migrations" ("identifier") VALUES (?)"#,
                    arguments: [rename.current]
                )
                try db.execute(
                    sql: #"DELETE FROM "grdb_migrations" WHERE "identifier" = ?"#,
                    arguments: [rename.legacy]
                )
            }
        }
    }

    /// The backfill, named so the migration and the test that proves what it
    /// does run the identical statement. Both id columns use GRDB's
    /// uppercase-string UUID strategy — verified in `Records.swift`, where
    /// `Card` and `StoryProposal` each declare it — so this equality holds; a
    /// lowercase id on either side would match nothing and pass as "nothing to
    /// backfill", which is indistinguishable from success.
    ///
    /// `LIMIT 1` is belt: acceptance creates one card per proposal, so at most
    /// one row can match — but a query that would return two rows in a scalar
    /// subquery is an error rather than a choice, and a migration is a bad
    /// place to learn that.
    ///
    /// `WHERE "angle" IS NULL` is not belt. This statement is also reachable
    /// through `BoardStore.backfillCardAngles()`, which is deliberately
    /// idempotent, so without the guard a re-run would overwrite a lens that
    /// had since been corrected with whatever the original proposal said.
    static let backfillCardAnglesSQL = """
        UPDATE "card" SET "angle" = (
            SELECT "p"."angle" FROM "storyProposal" "p"
            WHERE "p"."acceptedCardID" = "card"."id" LIMIT 1
        )
        WHERE "angle" IS NULL
        """

    /// The original schema. Named so a test can build a v1 database and prove
    /// the upgrade to the current schema loses nothing.
    static func v1Initial(_ db: Database) throws {
        try db.create(table: "repo") { t in
            t.primaryKey("id", .text)
            t.column("path", .text).notNull().unique()
            t.column("nameWithOwner", .text).notNull()
            t.column("defaultBranch", .text).notNull()
            t.column("displayName", .text).notNull()
            t.column("permissionMode", .text).notNull()
            // JSON array.
            t.column("extraAllowedTools", .text).notNull()
            t.column("isEnabled", .boolean).notNull()
        }

        try db.create(table: "card") { t in
            t.primaryKey("id", .text)
            t.column("repoID", .text).notNull()
                .references("repo", onDelete: .cascade)
            t.column("title", .text).notNull()
            t.column("body", .text).notNull()
            // JSON object, null for a card that is a plain note.
            t.column("story", .text)
            t.column("column", .text).notNull()
            t.column("orderIndex", .double).notNull()
            t.column("issueNumber", .integer)
            t.column("issueURL", .text)
            t.column("prNumber", .integer)
            t.column("prURL", .text)
            t.column("branch", .text)
            t.column("columnEnteredAt", .datetime).notNull()
            t.column("lastError", .text)
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
        }
        // The board's only read pattern: one repo, one column, in order.
        try db.create(
            index: "card_on_repo_column_order",
            on: "card",
            columns: ["repoID", "column", "orderIndex"]
        )

        try db.create(table: "skillRun") { t in
            t.primaryKey("id", .text)
            t.column("cardID", .text).notNull()
                .references("card", onDelete: .cascade)
            t.column("repoID", .text).notNull()
                .references("repo", onDelete: .cascade)
            t.column("kind", .text).notNull()
            t.column("prompt", .text).notNull()
            t.column("argv", .text).notNull()          // JSON array
            t.column("cwd", .text).notNull()
            t.column("state", .text).notNull()
            t.column("startedAt", .datetime)
            t.column("endedAt", .datetime)
            t.column("exitCode", .integer)
            t.column("logPath", .text).notNull()
            t.column("stderrPath", .text).notNull()
            t.column("resultText", .text)
            t.column("totalCostUSD", .double)
            t.column("numTurns", .integer)
            t.column("permissionDenials", .text).notNull()  // JSON array
            t.column("verifiedOutcome", .text)              // JSON object
            t.column("createdAt", .datetime).notNull()
        }
        try db.create(
            index: "skillRun_on_card_created",
            on: "skillRun",
            columns: ["cardID", "createdAt"]
        )
        // The launch sweep asks for every non-terminal run.
        try db.create(index: "skillRun_on_state", on: "skillRun", columns: ["state"])

        try db.create(table: "moveAudit") { t in
            t.primaryKey("id", .text)
            t.column("cardID", .text).notNull()
                .references("card", onDelete: .cascade)
            t.column("from", .text).notNull()
            t.column("to", .text).notNull()
            t.column("origin", .text).notNull()   // JSON object
            t.column("runID", .text)
            t.column("at", .datetime).notNull()
        }
        try db.create(index: "moveAudit_on_card_at", on: "moveAudit", columns: ["cardID", "at"])
    }

    static func v4Analysis(_ db: Database) throws {
        try db.create(table: "analysis") { t in
            t.primaryKey("id", .text)
            t.column("repoID", .text).notNull()
                .references("repo", onDelete: .cascade)
            t.column("angles", .text).notNull()              // JSON array
            t.column("extraInstructions", .text).notNull()
            t.column("maxStoriesPerAngle", .integer).notNull()
            t.column("origin", .text).notNull()              // JSON object
            t.column("createdAt", .datetime).notNull()
        }
        try db.create(index: "analysis_on_repo_created", on: "analysis", columns: ["repoID", "createdAt"])

        try db.create(table: "storyProposal") { t in
            t.primaryKey("id", .text)
            t.column("analysisID", .text).notNull()
                .references("analysis", onDelete: .cascade)
            t.column("runID", .text).notNull()
            t.column("repoID", .text).notNull()
                .references("repo", onDelete: .cascade)
            t.column("angle", .text).notNull()
            t.column("title", .text).notNull()
            t.column("story", .text).notNull()               // JSON object
            t.column("rationale", .text).notNull()
            t.column("evidence", .text).notNull()            // JSON array
            t.column("effort", .text).notNull()
            t.column("status", .text).notNull()
            t.column("acceptedCardID", .text)
            t.column("duplicateOf", .text)                   // JSON object, null when none
            t.column("createdAt", .datetime).notNull()
        }
        try db.create(
            index: "storyProposal_on_analysis_status",
            on: "storyProposal", columns: ["analysisID", "status"]
        )
        try db.create(
            index: "storyProposal_on_repo_status",
            on: "storyProposal", columns: ["repoID", "status"]
        )

        // SQLite cannot relax a NOT NULL in place, so the table is rebuilt.
        // A renamed table keeps its indexes under their original names, so the
        // new ones can only be created after the old table is dropped.
        try db.rename(table: "skillRun", to: "skillRun_old")
        try db.create(table: "skillRun") { t in
            t.primaryKey("id", .text)
            // Nullable now: an analysis run has no card.
            t.column("cardID", .text)
                .references("card", onDelete: .cascade)
            t.column("repoID", .text).notNull()
                .references("repo", onDelete: .cascade)
            t.column("analysisID", .text)
                .references("analysis", onDelete: .cascade)
            t.column("analysisAngle", .text)
            t.column("kind", .text).notNull()
            t.column("prompt", .text).notNull()
            t.column("argv", .text).notNull()
            t.column("cwd", .text).notNull()
            t.column("state", .text).notNull()
            t.column("startedAt", .datetime)
            t.column("endedAt", .datetime)
            t.column("exitCode", .integer)
            t.column("logPath", .text).notNull()
            t.column("stderrPath", .text).notNull()
            t.column("resultText", .text)
            t.column("totalCostUSD", .double)
            t.column("numTurns", .integer)
            t.column("permissionDenials", .text).notNull()
            t.column("verifiedOutcome", .text)
            t.column("analysisReport", .text)                // JSON object
            t.column("createdAt", .datetime).notNull()
            // A run works on a card or reads an analysis, never both and never
            // neither — checked here so the malformed row is refused by SQLite
            // even if it is ever reached some way other than the two factories.
            t.check(sql: #"("cardID" IS NULL) <> ("analysisID" IS NULL)"#)
        }
        try db.execute(sql: """
            INSERT INTO "skillRun" (
              "id","cardID","repoID","analysisID","analysisAngle","kind","prompt","argv","cwd",
              "state","startedAt","endedAt","exitCode","logPath","stderrPath","resultText",
              "totalCostUSD","numTurns","permissionDenials","verifiedOutcome","analysisReport",
              "createdAt"
            )
            SELECT
              "id","cardID","repoID",NULL,NULL,"kind","prompt","argv","cwd",
              "state","startedAt","endedAt","exitCode","logPath","stderrPath","resultText",
              "totalCostUSD","numTurns","permissionDenials","verifiedOutcome",NULL,
              "createdAt"
            FROM "skillRun_old"
            """)
        try db.drop(table: "skillRun_old")

        try db.create(index: "skillRun_on_card_created", on: "skillRun", columns: ["cardID", "createdAt"])
        try db.create(index: "skillRun_on_state", on: "skillRun", columns: ["state"])
        try db.create(index: "skillRun_on_analysis", on: "skillRun", columns: ["analysisID"])
    }
}
