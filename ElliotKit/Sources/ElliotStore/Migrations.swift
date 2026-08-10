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

        // v8, additive: what GitHub says about a pull request, dated and tied to
        // the commit it was read on.
        //
        // Its own table rather than columns on `card`, for one reason: `card`'s
        // fields are decided in exactly one place — `VerifiedOutcome.applied(to:)`
        // — and that invariant is kept by grep. A pull request's status is not
        // the outcome of a run; it is an observation about an object outside the
        // card, written by a poller. Mixing the two families on one type, with
        // nothing marking the boundary, is how the next person writes a card
        // field from the watcher and nobody notices.
        //
        // The states are TEXT and not enumerations on purpose. GitHub adds
        // `mergeStateStatus` values; a stored enum turns that into a decode
        // failure that takes the whole row, where a string reaches the reader
        // intact and renders as "not known".
        //
        // `checkedAt` and `headRefOid` are what make "I do not know" expressible
        // at all — without them a stale reading is indistinguishable from a
        // current one, which is the defect this board has already shipped twice
        // in other tools.
        migrator.registerMigration("v8_prStatus") { db in
            try db.create(table: "prStatus") { t in
                t.column("repoID", .text).notNull()
                    .references("repo", onDelete: .cascade)
                t.column("prNumber", .integer).notNull()
                t.column("headRefOid", .text).notNull()
                t.column("checkedAt", .datetime).notNull()
                t.column("rawMergeStateStatus", .text).notNull()
                t.column("rawMergeable", .text).notNull()
                t.column("rawReviewDecision", .text).notNull()
                // JSON: the rollup as `gh` rendered it, names and all, so the
                // panel can print what actually ran instead of a verdict.
                t.column("checks", .text).notNull()
                t.primaryKey(["repoID", "prNumber"])
            }
        }

        // v9, additive: the labels a card asks its issue to carry.
        //
        // NOT NULL with a `'[]'` default, where v2's `visibility` and v7's
        // `angle` are both nullable — and the difference is not a style choice.
        // Those two are `Optional` on `Card`, so a NULL decodes as "nothing was
        // said". `labels` is a non-optional `[String]`, and Swift's synthesised
        // decoder does not fall back to a property's default value: a NULL
        // column would throw `keyNotFound` on **every card written before this
        // migration**, which presents as a board that opens onto nothing and
        // blames the store rather than as a migration that went wrong.
        // `MigrationsTests` inserts a v8 card and reads it back for exactly
        // that reason.
        //
        // Text holding JSON, like `extraAllowedTools` and `permissionDenials`
        // before it — GRDB encodes a `[String]` that way for free, and a
        // separate `cardLabel` table would buy ordering and referential
        // integrity this does not want: the order is the writer's, and the
        // whole point of the field is that it may name a label the repository
        // does **not** have.
        //
        // No backfill, deliberately, and it is the one place this differs from
        // v7. The angle could be recovered because `storyProposal` had recorded
        // it since v4; nothing anywhere has ever recorded which labels an
        // existing card wanted. Deriving them now — from the card's angle, from
        // the words in its title — would be the invisible guess this feature
        // exists to replace, written into the database where nobody would ever
        // see it happen.
        migrator.registerMigration("v9_cardLabels") { db in
            try db.alter(table: "card") { t in
                t.add(column: "labels", .text).notNull().defaults(to: "[]")
            }
        }

        // v10, additive: what Preflight last said about a checkout, on the
        // registration row.
        //
        // ⚠️ **This shipped as `v9_repoPreflight` and moved to v10 at the merge**,
        // which is the rule this file states rather than an exception to it: two
        // unmerged branches both claimed v9, and `v9_cardLabels` reached `main`
        // first (#228). A migration's name is its identity in `grdb_migrations`,
        // so the one already in the field keeps its number and the unshipped one
        // moves — renaming `v9_cardLabels` instead would run a second, different
        // migration on every database that had already seen it. Nothing was in
        // the field under `v9_repoPreflight`, so moving it costs nothing.
        //
        // A measurement stored on a registration is a trade, and it is made
        // deliberately. The alternative was to hand `BoardService` a Preflight
        // collaborator, which would put a networked `gh label list` behind every
        // drag; this way the rule reads a column the funnel already loads, so a
        // drag, `board_move_card` and `board_next` cannot answer differently.
        //
        // **Nullable, with no default**, and both halves are deliberate.
        //
        // Nullable because `Repo.preflight` is an `Optional` — and it has to be,
        // so that `openReadOnly` keeps tolerating a database older than the
        // helper, where an added column reads as absent. A `NOT NULL` column
        // under an optional property is a constraint violation waiting for the
        // first repository registered without a sweep.
        //
        // No default of `'passing'`, obviously — but no default of
        // `'notChecked'` either, because NULL already *is* that answer and two
        // spellings of one state is how a reader ends up handling only one of
        // them. `Repo.preflightVerdict` folds NULL into `.notChecked` once.
        //
        // What matters is that neither spelling is a pass. Every row predating
        // this column has genuinely never been swept, and defaulting them to a
        // pass would be the same lie the change exists to remove:
        // `PreflightService.isBlocking([])` answering `false` for an unmeasured
        // repository is what let three documents assert a gate nobody had
        // written. (That function no longer exists — #302 replaced it with
        // `PreflightReading`, which cannot be built without a sweep — but the
        // column still has to survive the row it was written for.)
        migrator.registerMigration("v10_repoPreflight") { db in
            try db.alter(table: "repo") { t in
                t.add(column: "preflight", .text)
            }
        }

        // v11, additive: whose words a run's `resultText` holds.
        //
        // The column exists because one field held two kinds of thing —  the
        // agent's closing prose and, when the process died before emitting a
        // terminal event, its stderr — and recorded which of them nowhere, so
        // the panel captioned a machine's diagnosis "IT SAID" and set it in the
        // demoted face (#288).
        //
        // **Nullable, with no default**, and both halves are deliberate — the
        // same trade v10 made one table over, for the same reason.
        //
        // Nullable because `SkillRun.resultSource` is an `Optional`, and it has
        // to be so `openReadOnly` keeps tolerating a database older than the
        // helper, where an added column reads as absent.
        //
        // No default of `'agent'`, which is the tempting one: it is the
        // commonest case, and every row it touched would then *assert* an
        // author nobody recorded. ⛔ Nor may the source be inferred from a
        // proxy — `numTurns IS NULL`, a state of `failed`, an exit code —
        // because a guess written into the database is indistinguishable
        // afterwards from a measurement, and guessing is the whole of what this
        // column exists to stop. NULL means "nobody recorded it", and
        // `ClosingRemark` degrades that to the wording these rows already had
        // rather than claiming stderr for history it cannot know.
        //
        // No backfill for the same reason v9 had none: nothing anywhere has
        // ever recorded where an existing run's text came from.
        migrator.registerMigration("v11_runResultSource") { db in
            try db.alter(table: "skillRun") { t in
                t.add(column: "resultSource", .text)
            }
        }

        // v12, additive: what an appraisal established about a card's value.
        //
        // ⚠️ **This shipped as `v11_cardAppraisal` and moved to v12 at the
        // merge** — the second time this file has recorded that sentence, and it
        // is the rule rather than an exception to it. Two unmerged branches both
        // claimed v11; `v11_runResultSource` reached `main` first (#344), so it
        // keeps the number and the unshipped one moves. Renaming the shipped one
        // instead would run a second, different migration on every database that
        // had already seen it.
        //
        // No `RenamedMigration`, and that half is measured rather than assumed —
        // twice, because the answer changed underneath the first measurement. A
        // rename entry records a migration that *actually reached a database*
        // under the old name; `git log --all -S'cardAppraisal'` finds it on no
        // ref but this branch, and the developer's own store
        // (`~/Library/Application Support/Elliot`) holds `v1_initial …
        // v11_runResultSource` with **zero** rows matching `%cardAppraisal%`
        // under any number. Nothing was in the field under either name, so
        // moving it costs nothing — v10's precedent, one migration on.
        //
        // Columns on `card` rather than a table of its own, and the criterion is
        // the one written above v8. A pull request's status is an observation
        // about an object outside the card, written by a poller, so it got a
        // table. This is the opposite family: the appraisal run carries a
        // `cardID`, so `activeRun(cardID:)` holds the card for the run's whole
        // life and no poller can be half-way through the same row. That makes it
        // provenance, and v7's columns the right precedent.
        //
        // The counterpart is measured and favourable: `observeCards()` already
        // tracks the whole card row and de-duplicates, so a column write is
        // observable for free — a separate table would cost a second
        // `ValueObservation`.
        //
        // The backfill is not a guess. `storyProposal` has carried the effort,
        // the resolved citations and the moment they were resolved since v4,
        // next to the id of the card it produced, so every accepted card already
        // carries the answer one join away. Without this the feature would ship
        // empty on every existing board and look like a feature that does not
        // work — v7's stated reason, unchanged.
        migrator.registerMigration("v12_cardAppraisal") { db in
            try db.alter(table: "card") { t in
                t.add(column: "effort", .text)
                t.add(column: "evidence", .text)        // JSON array
                t.add(column: "appraisedAt", .datetime)
            }
            try db.execute(sql: Migrations.backfillCardAppraisalsSQL)
        }

        // Nullable, with **no default and no backfill** (#199, #200).
        //
        // ⛔ Defaulting existing rows to `LabelPolicy.default` is the tempting
        // one and it destroys the whole distinction: it would make every
        // repository in the field *assert* a taxonomy nobody chose, and the
        // check would then stop offering the conversation on exactly the
        // repositories that have never had it. NULL means "never asked"; an
        // empty JSON array means "asked, and chose to require nothing". Those
        // are different answers and the column exists to keep them apart.
        migrator.registerMigration("v13_repoLabelPolicy") { db in
            try db.alter(table: "repo") { t in
                t.add(column: "labelPolicy", .text)     // JSON array, or NULL
            }
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

    /// The v12 backfill, named for the same reason `backfillCardAnglesSQL` is:
    /// the migration and the test that proves what it does run the identical
    /// statement.
    ///
    /// Three correlated subqueries rather than one row-value assignment, so it
    /// reads the way v7's does and depends on nothing beyond what v7 already
    /// relies on. `LIMIT 1` is belt, for v7's reason: acceptance creates one
    /// card per proposal, so at most one row can match — but a subquery that
    /// would return two rows is an error rather than a choice, and a migration
    /// is a bad place to learn that.
    ///
    /// `appraisedAt` takes the proposal's `createdAt` and not the moment of the
    /// migration: that is when the harvest resolved the citations, and dating
    /// the reading to the upgrade would make every old board look freshly
    /// measured.
    ///
    /// `WHERE "appraisedAt" IS NULL` is not belt. This statement is also
    /// reachable through `BoardStore.backfillCardAppraisals()`, which is
    /// deliberately idempotent, so without the guard a re-run would overwrite an
    /// appraisal that had since been redone with whatever the original proposal
    /// said.
    ///
    /// The `EXISTS` is not redundant with the subqueries, and it is the one
    /// place this statement is not v7's shape. `backfillCardAnglesSQL` writes
    /// the single column it filters on, so a row it visits has NULL there by
    /// definition and nothing can be destroyed. This one filters on
    /// `appraisedAt` and assigns **three** columns: a card carrying an effort
    /// but no `appraisedAt`, with no proposal to read one from, is selected by
    /// the filter and then has that effort assigned the NULL of a subquery with
    /// nothing to return. `EXISTS` keeps the row guard and the assignment
    /// talking about the same thing. It only ever removes rows that could have
    /// received NULLs, so it changes no outcome that was already right.
    static let backfillCardAppraisalsSQL = """
        UPDATE "card" SET
            "effort" = (
                SELECT "p"."effort" FROM "storyProposal" "p"
                WHERE "p"."acceptedCardID" = "card"."id" LIMIT 1
            ),
            "evidence" = (
                SELECT "p"."evidence" FROM "storyProposal" "p"
                WHERE "p"."acceptedCardID" = "card"."id" LIMIT 1
            ),
            "appraisedAt" = (
                SELECT "p"."createdAt" FROM "storyProposal" "p"
                WHERE "p"."acceptedCardID" = "card"."id" LIMIT 1
            )
        WHERE "appraisedAt" IS NULL
          AND EXISTS (
            SELECT 1 FROM "storyProposal" "p" WHERE "p"."acceptedCardID" = "card"."id"
          )
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
