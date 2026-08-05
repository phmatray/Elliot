import Foundation
import GRDB

enum Migrations {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
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

        return migrator
    }
}
