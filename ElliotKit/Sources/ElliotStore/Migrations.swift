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

        // v6, additive: a card can now say which analysis lens found it.
        //
        // The backfill is not a guess. `storyProposal` has recorded both the
        // lens and the id of the card it produced since v4, so every card that
        // came from an analysis already carries the answer one join away —
        // without this, the feature would ship empty on every existing board
        // and look like a feature that does not work.
        migrator.registerMigration("v6_cardAngle") { db in
            try db.alter(table: "card") { t in
                t.add(column: "angle", .text)
            }
            try db.execute(sql: Migrations.backfillCardAnglesSQL)
        }

        return migrator
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
