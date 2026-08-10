import ElliotModel
import Foundation
import GRDB

/// The board's persistent state.
///
/// **The app is the sole writer.** SQLite does not notify other processes of
/// writes, so `ValueObservation` in the app would never see one made by the MCP
/// helper — the helper therefore opens the store read-only and routes every
/// mutation back through the app over IPC. That single rule is what makes
/// sharing one SQLite file between two processes trivially safe here.
public final class BoardStore: Sendable {
    private let writer: (any DatabaseWriter)?
    private let reader: any DatabaseReader

    // MARK: - Opening

    /// Opens the store for reading and writing, running migrations.
    public static func open(at url: URL? = nil) throws -> BoardStore {
        try StoreLocation.ensureDirectories()
        let path = (url ?? StoreLocation.databaseURL).path
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: path, configuration: config)
        // Before migrating, not during: a migration renamed while it sat
        // unmerged is unapplied by name on any machine that ran the old branch,
        // and would run a second time over the schema it already made.
        try Migrations.adoptRenamedMigrations(in: pool)
        try Migrations.migrator.migrate(pool)
        return BoardStore(writer: pool)
    }

    /// Opens the store read-only, for the MCP helper when the app is down.
    ///
    /// Never migrates: an old helper meeting a newer schema must fail loudly
    /// rather than rewrite a database it does not own. That refusal is now
    /// checked rather than only intended — until there was a second migration
    /// it could not happen, and the door was never actually shut.
    ///
    /// The opposite direction is left open on purpose. A helper that knows a
    /// migration the file has not run reads the added columns as absent, and
    /// GRDB decodes an absent optional as `nil` — which is the truth, since
    /// nothing could have written a value the column does not exist to hold.
    /// Refusing there would blank the board for the whole window between an
    /// upgrade and the next launch of the app, and answer "Elliot is not
    /// running" to a question the file can answer correctly.
    public static func openReadOnly(at url: URL? = nil) throws -> BoardStore {
        let path = (url ?? StoreLocation.databaseURL).path
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.readonly = true
        let queue = try DatabaseQueue(path: path, configuration: config)

        let migrator = Migrations.migrator
        let applied = try queue.read { db in try migrator.appliedIdentifiers(db) }
        // A readable file that no migration ever touched is not this board.
        // Saying so at the door beats "no such table: card" from inside a tool.
        guard !applied.isEmpty else { throw StoreError.schemaMissing }
        guard applied.isSubset(of: Set(migrator.migrations)) else { throw StoreError.schemaTooNew }

        return BoardStore(reader: queue)
    }

    /// An in-memory store, for tests.
    public static func inMemory() throws -> BoardStore {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue)
        return BoardStore(writer: queue)
    }

    private init(writer: any DatabaseWriter) {
        self.writer = writer
        self.reader = writer
    }

    private init(reader: any DatabaseReader) {
        self.writer = nil
        self.reader = reader
    }

    public var isWritable: Bool { writer != nil }

    private func requireWriter() throws -> any DatabaseWriter {
        guard let writer else { throw StoreError.readOnly }
        return writer
    }

    /// Raw SQL, for tests only.
    ///
    /// **`internal`, so only `@testable import` reaches it** — the app and the
    /// MCP helper cannot call this, which is the point. It exists because some
    /// claims are about rows the *type system cannot write*: a `skillRun` whose
    /// `kind` is a skill this build has never heard of is what a newer build
    /// leaves behind, and `daySpend`'s two-statement shape is written for
    /// exactly that row. There is no way to produce it through `saveRun`, so
    /// without this the reasoning in that comment could only be asserted.
    ///
    /// ⛔ Not a general escape hatch. Anything a test can express through the
    /// typed API belongs there: raw SQL passes straight through the schema, so
    /// it can also create rows no migration would ever produce, which is a test
    /// proving something about a database that cannot exist.
    func testOnlyExecute(_ sql: String) async throws {
        try await requireWriter().write { db in try db.execute(sql: sql) }
    }

    // MARK: - Repos

    public func saveRepo(_ repo: Repo) async throws {
        try await requireWriter().write { db in try repo.save(db) }
    }

    /// Writes Preflight's verdict and **only** Preflight's verdict.
    ///
    /// `AppModel.refreshRepoChecks` captures `repos`, then per repository awaits
    /// `preflight.repoChecks(repo)` — which shells out to `gh` and `git`, so the
    /// suspension is seconds long, not microseconds. Writing the captured row
    /// back through ``saveRepo(_:)`` therefore reverts anything saved during
    /// that window, and a first sweep after launch moves every repository from
    /// `notChecked`, so the window opens for all of them at once.
    ///
    /// The hazard has existed since the verdict was persisted and never
    /// mattered, because `isEnabled` and a sweep are rarely touched together. It
    /// starts mattering the moment the field being silently reverted is the one
    /// bounding what an unattended agent may do to a checkout: a safety control
    /// that quietly returns to `bypassPermissions` while the screen still shows
    /// the tightened value is worse than no control at all.
    ///
    /// A single-column `UPDATE` rather than a read-modify-write, so there is no
    /// window of its own to reason about.
    public func saveRepoPreflight(id: UUID, verdict: PreflightState) async throws {
        _ = try await requireWriter().write { db in
            try db.execute(
                sql: "UPDATE repo SET preflight = ? WHERE id = ?",
                arguments: [verdict.rawValue, id.databaseKey]
            )
        }
    }

    /// Writes the chosen method and **only** the chosen method.
    ///
    /// The sibling above earns its shape from a seconds-long suspension. This
    /// one has no network call in it at all, and is still a single-column
    /// `UPDATE` — because the argument that matters is the last line of that
    /// doc comment rather than the first: *no window of its own to reason
    /// about*. A read-modify-write here would narrow the hazard from "a whole
    /// sweep" to "two store calls" and leave the reader a race to think about
    /// every time this is read. There is no version of that which is worth
    /// having for one scalar column.
    ///
    /// It shipped as `var updated = repo; updated.methodID = …; saveRepo(updated)`
    /// — the whole row, from the copy the menu was rendering. What the field
    /// being reverted was decides how bad that is, and the answer moved: `Repo`
    /// gained `permissionMode` and `extraAllowedTools` in #333, so a picker
    /// built on a pre-tightening snapshot put `bypassPermissions` back.
    ///
    /// `nil` is a value here, not a missing argument: it clears the column and
    /// the repository resolves as `.unset` again. `Optional<String>` binds as
    /// `NULL`, which is what the v15 migration deliberately left backfill-free.
    ///
    /// Returns whether a row was actually updated. `false` means the repository
    /// is gone — Preflight carries a Forget button, so a menu can outlive its
    /// row — and the caller has a sentence to show for that. Reading the row
    /// back to find out instead would reintroduce exactly the window this
    /// spelling exists to avoid.
    public func saveRepoMethod(id: UUID, methodID: String?) async throws -> Bool {
        try await requireWriter().write { db in
            try db.execute(
                sql: "UPDATE repo SET methodID = ? WHERE id = ?",
                arguments: [methodID, id.databaseKey]
            )
            return db.changesCount > 0
        }
    }

    public func deleteRepo(id: UUID) async throws {
        _ = try await requireWriter().write { db in try Repo.deleteOne(db, key: id.databaseKey) }
    }

    /// What `deleteRepo` would destroy, counted in one read.
    ///
    /// One transaction, so the four numbers are one snapshot rather than four
    /// readings a write could slip between. Built from the **same** private
    /// filters the list queries use — `cardFilter`, `runFilter`, `proposalQuery`
    /// — so "this repository's runs" has one definition and the count cannot
    /// disagree with the rows it describes.
    ///
    /// `prStatus`, `dismissedExternal` and `moveAudit` cascade too and are
    /// deliberately not counted: they are readings derived from this work, not
    /// work. The confirmation names them as a clause.
    public func forgetImpact(repoID: UUID) async throws -> ForgetImpact {
        try await reader.read { db in
            let cards = try Self.cardFilter(repoID: repoID, column: nil).fetchCount(db)
            let runs = try Self.runFilter(cardID: nil, repoID: repoID).fetchCount(db)
            let analyses = try Analysis
                .filter(Analysis.Columns.repoID == repoID.databaseKey)
                .fetchCount(db)
            let proposals = try Self
                .proposalQuery(analysisID: nil, repoID: repoID, runID: nil, status: nil)
                .fetchCount(db)
            return ForgetImpact(
                cards: cards, runs: runs, analyses: analyses, proposals: proposals)
        }
    }

    public func repos() async throws -> [Repo] {
        try await reader.read { db in
            try Repo.order(SQLColumn("displayName")).fetchAll(db)
        }
    }

    public func repo(id: UUID) async throws -> Repo? {
        try await reader.read { db in try Repo.fetchOne(db, key: id.databaseKey) }
    }

    public func repo(path: String) async throws -> Repo? {
        try await reader.read { db in
            try Repo.filter(SQLColumn("path") == path).fetchOne(db)
        }
    }

    // MARK: - Pull request status

    /// Records one reading. Keyed by `(repoID, prNumber)`, so a second reading
    /// of the same pull request replaces the first rather than accumulating
    /// history — the board wants the current answer, and an old reading is
    /// exactly what `PRStatus.resolved` refuses to report anyway.
    public func savePRStatus(_ status: PRStatus) async throws {
        try await requireWriter().write { db in try status.save(db) }
    }

    public func prStatus(repoID: UUID, prNumber: Int) async throws -> PRStatus? {
        try await reader.read { db in
            try PRStatus
                .filter(PRStatus.Columns.repoID == repoID.databaseKey)
                .filter(PRStatus.Columns.prNumber == prNumber)
                .fetchOne(db)
        }
    }

    public func prStatuses(repoID: UUID) async throws -> [PRStatus] {
        try await reader.read { db in
            try PRStatus
                .filter(PRStatus.Columns.repoID == repoID.databaseKey)
                .order(PRStatus.Columns.prNumber)
                .fetchAll(db)
        }
    }

    // MARK: - Settings

    private static let layoutKey = "repositoryLayout"

    public func layout() async throws -> RepoTreeLayout? {
        try await setting(Self.layoutKey, as: RepoTreeLayout.self)
    }

    public func saveLayout(_ layout: RepoTreeLayout) async throws {
        try await saveSetting(Self.layoutKey, layout)
    }

    private static let limitsKey = "schedulerLimits"

    /// `nil` when nothing has been chosen — the caller applies
    /// `SchedulerLimits.default`, so an existing store behaves as it always did.
    public func limits() async throws -> SchedulerLimits? {
        try await setting(Self.limitsKey, as: SchedulerLimits.self)
    }

    public func saveLimits(_ limits: SchedulerLimits) async throws {
        try await saveSetting(Self.limitsKey, limits)
    }

    private static let ceilingKey = "spendCeiling"

    public func spendCeiling() async throws -> SpendCeiling? {
        try await setting(Self.ceilingKey, as: SpendCeiling.self)
    }

    public func saveSpendCeiling(_ ceiling: SpendCeiling) async throws {
        try await saveSetting(Self.ceilingKey, ceiling)
    }

    /// What has been spent since `since`, summed in SQL.
    ///
    /// Keyed on `endedAt`, not `createdAt`: a run's cost is only known once it
    /// has finished, so a run that started yesterday and ended today spent its
    /// money today. Runs still in flight contribute nothing, which is the honest
    /// answer — their cost does not exist yet.
    ///
    /// A NULL `totalCostUSD` is **not** counted as zero. A run whose cost was
    /// never recorded must not read the same as a run that cost nothing; the
    /// same distinction `workingTreeChanged` draws between checked-and-clean and
    /// never-checked. The count comes back so a caller can tell a partial answer
    /// from a complete one.
    public func spend(since: Date) async throws -> Spend {
        try await reader.read { db in
            let row = try Row.fetchOne(
                db,
                sql: #"""
                    SELECT
                        COALESCE(SUM("totalCostUSD"), 0.0) AS total,
                        COUNT(*) AS runs,
                        SUM(CASE WHEN "totalCostUSD" IS NULL THEN 1 ELSE 0 END) AS unknown
                    FROM "skillRun"
                    WHERE "endedAt" IS NOT NULL AND "endedAt" >= ?
                    """#,
                arguments: [since]
            )
            guard let row else { return Spend.nothing }
            return Spend(
                totalUSD: row["total"] ?? 0,
                runs: row["runs"] ?? 0,
                unknownCost: row["unknown"] ?? 0
            )
        }
    }

    /// Spend since `since`, split by repository, biggest first.
    ///
    /// One statement with a GROUP BY rather than one query per repository: on a
    /// portfolio this is the difference between a page load and three hundred.
    public func spendByRepo(since: Date) async throws -> [(repoID: UUID, spend: Spend)] {
        try await reader.read { db in
            try Row.fetchAll(
                db,
                sql: #"""
                    SELECT
                        "repoID",
                        COALESCE(SUM("totalCostUSD"), 0.0) AS total,
                        COUNT(*) AS runs,
                        SUM(CASE WHEN "totalCostUSD" IS NULL THEN 1 ELSE 0 END) AS unknown
                    FROM "skillRun"
                    WHERE "endedAt" IS NOT NULL AND "endedAt" >= ?
                    GROUP BY "repoID"
                    ORDER BY total DESC
                    """#,
                arguments: [since]
            )
            .compactMap { row -> (repoID: UUID, spend: Spend)? in
                guard let id: UUID = row["repoID"] else { return nil }
                return (
                    id,
                    Spend(
                        totalUSD: row["total"] ?? 0,
                        runs: row["runs"] ?? 0,
                        unknownCost: row["unknown"] ?? 0
                    )
                )
            }
        }
    }

    /// Spend since `since`, split by what the run was doing.
    ///
    /// Answers the question the analysis setup screen raises and never answered:
    /// what a six-lens read actually costs, as against filing an issue.
    ///
    /// The decode happens *inside* the read block, like every other aggregate here.
    /// Handing `[Row]` back out would not merely be untidy: `Row` is not `Sendable`,
    /// so the `async` overload of `read` stops applying and the call quietly resolves
    /// to the blocking one — `await` on an expression that never suspends, holding a
    /// cooperative thread for the length of the query.
    public func spendByKind(since: Date) async throws -> [SkillKind: Spend] {
        try await reader.read { db in
            try Row.fetchAll(
                db,
                sql: #"""
                    SELECT
                        "kind",
                        COALESCE(SUM("totalCostUSD"), 0.0) AS total,
                        COUNT(*) AS runs,
                        SUM(CASE WHEN "totalCostUSD" IS NULL THEN 1 ELSE 0 END) AS unknown
                    FROM "skillRun"
                    WHERE "endedAt" IS NOT NULL AND "endedAt" >= ?
                    GROUP BY "kind"
                    """#,
                arguments: [since]
            )
            .reduce(into: [SkillKind: Spend]()) { byKind, row in
                guard let raw: String = row["kind"], let kind = SkillKind(rawValue: raw) else { return }
                byKind[kind] = Spend(
                    totalUSD: row["total"] ?? 0,
                    runs: row["runs"] ?? 0,
                    unknownCost: row["unknown"] ?? 0
                )
            }
        }
    }

    /// The day's spend, total and split by skill, from **one** boundary.
    ///
    /// The two aggregates above were both public and both took a `since`, and
    /// the only caller that wants both — a screen showing a total with its
    /// breakdown under it — had to read the clock twice. Across midnight those
    /// are two different days: the split would then not add up to the total
    /// beside it, silently, on the one screen whose subject is money.
    ///
    /// So the boundary is taken once here and travels in the answer. Nothing is
    /// computed that the two queries did not already compute; what this method
    /// adds is that the pair cannot be assembled from two midnights.
    ///
    /// Two statements rather than one grouped query with a rollup: the total
    /// must keep counting runs whose `kind` no longer decodes, which a `GROUP BY`
    /// summed in Swift would quietly drop — `spendByKind` skips an unknown raw
    /// value, and it is right to.
    public func daySpend(since: Date) async throws -> DaySpend {
        DaySpend(
            since: since,
            total: try await spend(since: since),
            byKind: try await spendByKind(since: since)
        )
    }

    /// What one analysis cost, across all of its lenses.
    public func spend(analysisID: UUID) async throws -> Spend {
        try await reader.read { db in
            let row = try Row.fetchOne(
                db,
                sql: #"""
                    SELECT
                        COALESCE(SUM("totalCostUSD"), 0.0) AS total,
                        COUNT(*) AS runs,
                        SUM(CASE WHEN "totalCostUSD" IS NULL THEN 1 ELSE 0 END) AS unknown
                    FROM "skillRun"
                    WHERE "analysisID" = ? AND "endedAt" IS NOT NULL
                    """#,
                arguments: [analysisID.databaseKey]
            )
            guard let row else { return Spend.nothing }
            return Spend(
                totalUSD: row["total"] ?? 0,
                runs: row["runs"] ?? 0,
                unknownCost: row["unknown"] ?? 0
            )
        }
    }

    /// What is on each repository's board, as of one pass.
    ///
    /// Three grouped reads and not one query per repository, for the reason
    /// `spendByRepo` gives: on this portfolio that is the difference between a
    /// page load and three hundred. The spend half *is* `spendByRepo`, reused
    /// rather than restated.
    ///
    /// A repository with nothing at all — no cards, no runs, nothing spent — is
    /// **absent** from the answer, the way a silent repository is absent from
    /// `spendByRepo`. That absence is deliberate and is the seam
    /// `RepoBoardDigest` turns into `.empty`: a `LEFT JOIN` over every
    /// registration here would answer criterion 3 in SQL, where no test of the
    /// entitlement rule could reach it.
    ///
    /// `since` is a parameter rather than a clock inside the store, matching
    /// `spend(since:)`, and it applies to **spend only**. Cards and runs in
    /// flight are the board's state now, not a window over it.
    ///
    /// The decode happens inside each `read` block, like every other aggregate
    /// here: `Row` is not `Sendable`, so handing rows out silently resolves
    /// `read` to the blocking overload — see the note on `spendByKind`.
    public func repoBoardTallies(since: Date) async throws -> [UUID: RepoBoardTally] {
        let cards = try await reader.read { db in
            try Row.fetchAll(
                db,
                Card.select(Card.Columns.repoID, count(Card.Columns.id).forKey("n"))
                    .group(Card.Columns.repoID)
            )
            .reduce(into: [UUID: Int]()) { counts, row in
                guard let id: UUID = row["repoID"] else { return }
                counts[id] = row["n"] ?? 0
            }
        }
        // `Self.activeStates` rather than a state list written out here: a
        // second copy of "in flight" is a second answer to it, and this one
        // would drift from the one `nonTerminalRuns()` and `activeRuns` share.
        let inFlight = try await reader.read { db in
            try Row.fetchAll(
                db,
                SkillRun
                    .filter(Self.activeStates.contains(SkillRun.Columns.state))
                    .select(SkillRun.Columns.repoID, count(SkillRun.Columns.id).forKey("n"))
                    .group(SkillRun.Columns.repoID)
            )
            .reduce(into: [UUID: Int]()) { counts, row in
                guard let id: UUID = row["repoID"] else { return }
                counts[id] = row["n"] ?? 0
            }
        }
        let spend = Dictionary(
            try await spendByRepo(since: since).map { ($0.repoID, $0.spend) },
            uniquingKeysWith: { first, _ in first })

        // The union of the three, not the card count filtered by the others: a
        // repository whose cards were forgotten still spent what it spent, and
        // a run can outlive the card that started it.
        var tallies: [UUID: RepoBoardTally] = [:]
        for id in Set(cards.keys).union(inFlight.keys).union(spend.keys) {
            tallies[id] = RepoBoardTally(
                cards: cards[id] ?? 0,
                runsInFlight: inFlight[id] ?? 0,
                spendToday: spend[id] ?? .nothing)
        }
        return tallies
    }

    /// The two halves of the settings pair, written once.
    ///
    /// `layout` had its own copy of both, and the scheduler limits would have
    /// made a second — at which point the next setting makes a third and one of
    /// them forgets the upsert.
    private func setting<T: Decodable>(_ key: String, as type: T.Type) async throws -> T? {
        let json = try await reader.read { db in
            try String.fetchOne(
                db, sql: #"SELECT "value" FROM "setting" WHERE "key" = ?"#,
                arguments: [key])
        }
        guard let data = json?.data(using: .utf8) else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }

    private func saveSetting(_ key: String, _ value: some Encodable) async throws {
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try await requireWriter().write { db in
            try db.execute(
                sql: #"""
                    INSERT INTO "setting" ("key", "value") VALUES (?, ?)
                    ON CONFLICT("key") DO UPDATE SET "value" = excluded."value"
                    """#,
                arguments: [key, json])
        }
    }

    // MARK: - Cards

    public func saveCard(_ card: Card) async throws {
        var card = card
        card.updatedAt = Date()
        try await requireWriter().write { [card] db in try card.save(db) }
    }

    /// Writes an appraisal onto a card, reading and writing in **one
    /// transaction**.
    ///
    /// Deliberately not `saveCard(_:)`. That takes a whole `Card` the caller read
    /// some `await`s earlier and writes every column of it — which is how a move
    /// committed in between loses its column, and how an appraisal written the
    /// other way round loses its three fields. Here the read and the write are
    /// the same transaction, so there is no window to lose anything in.
    ///
    /// Three fields and no more, for the reason the v8 migration records: what
    /// writes a card field is supposed to be enumerable. This is the fourth
    /// writer, it is named, and it can write nothing else.
    ///
    /// Answers with the card as it now stands, or `nil` if it has been deleted —
    /// which is not an error. A card can be forgotten while a run that mentions
    /// it is still finishing.
    @discardableResult
    public func applyAppraisal(
        cardID: UUID, effort: Effort, evidence: [Evidence], at: Date
    ) async throws -> Card? {
        // `db -> Card? in` spelled out: the closure's only `nil` is a bare
        // `return nil`, and leaving the optionality to inference is the classic
        // way to end up with `T == Card` and an error on that line.
        try await requireWriter().write { db -> Card? in
            guard var card = try Card.fetchOne(db, key: cardID.databaseKey) else { return nil }
            card.effort = effort
            card.evidence = evidence
            card.appraisedAt = at
            card.updatedAt = Date()
            try card.update(db)
            return card
        }
    }

    /// Runs the v6 backfill again. Idempotent — it only writes rows whose
    /// `angle` is still NULL — and exists so a test can assert what the
    /// migration does without reaching into `grdb_migrations`.
    ///
    /// Deliberately not `updatedAt`-touching: giving a card its lens back is
    /// recovering a fact it always had, not editing it, and bumping the
    /// timestamp would reorder every backfilled card against work that really
    /// did change.
    public func backfillCardAngles() async throws {
        try await requireWriter().write { db in
            try db.execute(sql: Migrations.backfillCardAnglesSQL)
        }
    }

    /// Runs the v12 backfill again. Idempotent — it only writes a card whose
    /// `appraisedAt` is still NULL **and** which has a proposal to read one
    /// from, so it can neither redo an appraisal nor blank one it has nothing
    /// to say about — and exists so a test can assert what the migration does
    /// without reaching into `grdb_migrations`.
    public func backfillCardAppraisals() async throws {
        try await requireWriter().write { db in
            try db.execute(sql: Migrations.backfillCardAppraisalsSQL)
        }
    }

    public func deleteCard(id: UUID) async throws {
        _ = try await requireWriter().write { db in try Card.deleteOne(db, key: id.databaseKey) }
    }

    public func card(id: UUID) async throws -> Card? {
        try await reader.read { db in try Card.fetchOne(db, key: id.databaseKey) }
    }

    /// The card an idempotency key already produced, if any.
    ///
    /// Keys are unique board-wide rather than per repository, because this
    /// lookup names only the key: one that could repeat across repositories
    /// would answer with an arbitrary one of them, and the second create the
    /// key exists to prevent would go through half the time.
    public func card(idempotencyKey: String) async throws -> Card? {
        try await reader.read { db in
            try Card.filter(Card.Columns.idempotencyKey == idempotencyKey).fetchOne(db)
        }
    }

    public func cards(
        repoID: UUID? = nil,
        column: ElliotModel.Column? = nil,
        limit: Int? = nil
    ) async throws -> [Card] {
        try await reader.read { db in
            try Self.cardQuery(repoID: repoID, column: column, limit: limit).fetchAll(db)
        }
    }

    /// How many cards the same filter matches, before any limit.
    ///
    /// Counted by SQL over the very request the page is cut from, so a page
    /// cannot be wrong about how much it left out. Fetching the rows to count
    /// them would also defeat the limit that made the count necessary.
    public func cardCount(repoID: UUID? = nil, column: ElliotModel.Column? = nil) async throws -> Int {
        try await reader.read { db in
            try Self.cardFilter(repoID: repoID, column: column).fetchCount(db)
        }
    }

    private static func cardFilter(
        repoID: UUID?,
        column: ElliotModel.Column?
    ) -> QueryInterfaceRequest<Card> {
        var request = Card.all()
        if let repoID {
            request = request.filter(Card.Columns.repoID == repoID.databaseKey)
        }
        if let column {
            request = request.filter(Card.Columns.column == column.rawValue)
        }
        return request
    }

    /// The filter, ordered and cut in SQL.
    ///
    /// `orderIndex` restarts at 1024 in every (repo, column) pair, so ordering
    /// by it alone leaves any listing spanning more than one of them in
    /// whatever order SQLite finds convenient — and a limit then cuts an
    /// arbitrary set out of that. Repository name, board order, position, id;
    /// the last key is there so no two rows can tie and no two calls against an
    /// unchanged board can disagree.
    ///
    /// `card_on_repo_column_order` no longer serves this: the subquery and the
    /// CASE make it a scan and a sort. Deliberate, and measured against what a
    /// personal board holds — a few hundred rows. Past that, denormalise the
    /// repository name onto the card row rather than giving the order up.
    private static func cardQuery(
        repoID: UUID?,
        column: ElliotModel.Column?,
        limit: Int?
    ) -> QueryInterfaceRequest<Card> {
        let request = cardFilter(repoID: repoID, column: column)
            .order(repoDisplayName, boardOrder, Card.Columns.orderIndex, Card.Columns.id)
        guard let limit else { return request }
        return request.limit(limit)
    }

    /// Sorted on the repository's name, not its id: an id is stable but says
    /// nothing to whoever reads a page spanning several repositories. A
    /// correlated subquery rather than a join, so the request stays a plain
    /// `Card` query that `observeCards` can go on sharing.
    private static let repoDisplayName = SQL(
        sql: #"(SELECT "repo"."displayName" FROM "repo" WHERE "repo"."id" = "card"."repoID")"#
    )

    /// Board order, not alphabetical — sorted on the raw value, `done` comes
    /// first. Derived from `Column.allCases` so a sixth column cannot be added
    /// without taking its place in the ranking too.
    private static let boardOrder: SQL = {
        let cases = ElliotModel.Column.allCases
        let whens = cases.enumerated()
            .map { rank, column in #"WHEN '\#(column.rawValue)' THEN \#(rank)"# }
            .joined(separator: " ")
        return SQL(sql: #"CASE "card"."column" \#(whens) ELSE \#(cases.count) END"#)
    }()

    // MARK: - The finished history

    /// Every finished card, newest first, paged.
    ///
    /// The board draws a horizon over Done and counts what it hid; this is
    /// where the hidden part is read back from. Ordered on `columnEnteredAt`
    /// rather than `orderIndex`, because for a finished card the latter records
    /// a position chosen while it was still in play.
    ///
    /// `id` is the last sort key for the reason `cardQuery` gives: two cards
    /// finished in the same second must not be able to swap places between two
    /// calls, or a page boundary would show one twice and the other never.
    public func doneCards(
        repoID: UUID? = nil,
        search: String? = nil,
        limit: Int,
        offset: Int = 0
    ) async throws -> [Card] {
        try await reader.read { db in
            try Self.doneFilter(repoID: repoID, search: search)
                .order(Card.Columns.columnEnteredAt.desc, Card.Columns.id.desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    /// How many rows the same filter matches, before the page is cut.
    ///
    /// Counted in SQL over the very request the page comes from — the contract
    /// `cardCount(repoID:column:)` already states, and the thing that lets the
    /// archive know whether another page exists. A count taken over a different
    /// filter would offer a "Load more" that loads nothing.
    public func doneCardCount(repoID: UUID? = nil, search: String? = nil) async throws -> Int {
        try await reader.read { db in
            try Self.doneFilter(repoID: repoID, search: search).fetchCount(db)
        }
    }

    /// Finished cards, optionally one repository's, optionally matching a term.
    ///
    /// **`instr`, deliberately, and not `LIKE`.** `%` and `_` are wildcards to
    /// `LIKE`, so a search box built on it needs every term escaped and an
    /// `ESCAPE` clause to go with it — and the failure mode of getting that
    /// wrong is silent and generous: typing `%` returns the whole archive and
    /// looks like a successful search. `instr` has no pattern language, so
    /// there is no escaping to get wrong.
    ///
    /// **Both sides are folded by the same `lower`, SQLite's.** Folding the
    /// needle in Swift instead looks equivalent and is not: `String.lowercased()`
    /// is Unicode-aware and maps `É → é`, while SQLite's built-in `lower()` is
    /// ASCII-only and leaves `É` alone. A card titled "ÉCRIRE la doc" was then
    /// findable by *neither* `écrire` (needle folded, haystack not) nor
    /// `ÉCRIRE` (needle folded away from a haystack that kept its accents) —
    /// unfindable by any query at all. Same fold on both sides, and the
    /// case-insensitivity is honestly ASCII-only rather than accidentally
    /// asymmetric.
    ///
    /// A term that is entirely digits also matches an issue or pull request
    /// number, which is how you find a card whose title you have forgotten.
    private static func doneFilter(repoID: UUID?, search: String?) -> QueryInterfaceRequest<Card> {
        var request = Card.all()
            .filter(Card.Columns.column == ElliotModel.Column.done.rawValue)
        if let repoID {
            request = request.filter(Card.Columns.repoID == repoID.databaseKey)
        }

        let term = search?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !term.isEmpty else { return request }

        var condition: SQL = """
            (instr(lower("card"."title"), lower(\(term))) > 0 \
            OR instr(lower("card"."body"), lower(\(term))) > 0
            """
        if let number = Int(term) {
            condition = condition + """
                 OR "card"."issueNumber" = \(number) OR "card"."prNumber" = \(number)
                """
        }
        condition = condition + ")"

        return request.filter(literal: condition)
    }

    /// Live cards for the board. Only fires on an actual change.
    public func observeCards(repoID: UUID? = nil) -> AsyncValueObservation<[Card]> {
        ValueObservation
            .tracking { db in
                try Self.cardQuery(repoID: repoID, column: nil, limit: nil).fetchAll(db)
            }
            .removeDuplicates()
            .values(in: reader)
    }

    /// Live pull request readings, board-wide.
    ///
    /// This exists because nothing else could deliver them. `PRWatcher` writes
    /// only to `prStatus` and touches no card row, so a board refreshing off the
    /// card observation would learn about a reading exactly never: the card
    /// reaches In Review, the refresh runs and finds nothing (the `gh pr view`
    /// has not returned yet), the row lands a moment later and nothing fires.
    /// Checks going from running to failed five minutes on would not arrive
    /// either. The feature would look like it did not work.
    ///
    /// Not keyed by card: the reader joins on `(repoID, prNumber)`, and a
    /// per-card observation would mean one observation per waiting card.
    public func observePRStatuses() -> AsyncValueObservation<[PRStatus]> {
        ValueObservation
            .tracking { db in try PRStatus.fetchAll(db) }
            .removeDuplicates()
            .values(in: reader)
    }

    /// Every repository row, decoded **one at a time**.
    ///
    /// `fetchAll` decodes the whole set or throws, so a single row Elliot cannot
    /// read used to cost the entire list — and with it the board, which sat on
    /// "Still starting" for ever (#118). Row by row, one bad row costs one
    /// repository.
    ///
    /// The count of skipped rows is carried out with the good ones rather than
    /// dropped, because dropping it silently would be the same defect with a
    /// smaller radius: a board quietly showing fewer repositories than exist is
    /// still a board saying "fine" when the answer is "I could not read this".
    ///
    /// `try?` is deliberate and narrow. It swallows nothing — the row is
    /// counted, and the count is rendered — and there is no useful distinction
    /// to draw between the ways a row can fail to decode, because none of them
    /// leaves anything on the row worth reporting.
    public func observeRepos() -> AsyncValueObservation<RepoScan> {
        ValueObservation
            .tracking { db in
                var repos: [Repo] = []
                var unreadable = 0
                for row in try Row.fetchAll(db, Repo.order(SQLColumn("displayName"))) {
                    if let repo = try? Repo(row: row) {
                        repos.append(repo)
                    } else {
                        unreadable += 1
                    }
                }
                return RepoScan(repos: repos, unreadable: unreadable)
            }
            .removeDuplicates()
            .values(in: reader)
    }

    /// The next `orderIndex` at the bottom of a column.
    public func nextOrderIndex(repoID: UUID, column: ElliotModel.Column) async throws -> Double {
        let maximum = try await reader.read { db in
            try Double.fetchOne(
                db,
                sql: #"SELECT MAX("orderIndex") FROM "card" WHERE "repoID" = ? AND "column" = ?"#,
                arguments: [repoID.databaseKey, column.rawValue]
            )
        }
        return (maximum ?? 0) + 1024
    }

    // MARK: - Runs

    public func run(id: UUID) async throws -> SkillRun? {
        try await reader.read { db in try SkillRun.fetchOne(db, key: id.databaseKey) }
    }

    public func runs(cardID: UUID? = nil, repoID: UUID? = nil, limit: Int = 100) async throws -> [SkillRun] {
        try await reader.read { db in
            try Self.runFilter(cardID: cardID, repoID: repoID)
                // Two runs of the same card can share a timestamp — a move that
                // triggers one is quick. The id breaks the tie so the page a
                // limit cuts is the same page twice running.
                .order(SkillRun.Columns.createdAt.desc, SkillRun.Columns.id)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// How many runs the same filter matches, before any limit.
    public func runCount(cardID: UUID? = nil, repoID: UUID? = nil) async throws -> Int {
        try await reader.read { db in
            try Self.runFilter(cardID: cardID, repoID: repoID).fetchCount(db)
        }
    }

    private static func runFilter(cardID: UUID?, repoID: UUID?) -> QueryInterfaceRequest<SkillRun> {
        var request = SkillRun.all()
        if let cardID {
            request = request.filter(SkillRun.Columns.cardID == cardID.databaseKey)
        }
        if let repoID {
            request = request.filter(SkillRun.Columns.repoID == repoID.databaseKey)
        }
        return request
    }

    public func saveRun(_ run: SkillRun) async throws {
        try await requireWriter().write { db in try run.save(db) }
    }

    /// Inserts a run **only if** no active run already holds its card.
    ///
    /// The same compare-and-set `claimProposal` is, and for the same reason: a
    /// "fetch, check, insert" written out by the caller reads a snapshot and
    /// writes across an `await`, so two starts for one card can both pass the
    /// check before either writes. Here the check and the insert are one
    /// transaction.
    ///
    /// `false` is a refusal, not an error: somebody else holds the card, which
    /// is exactly what the caller wanted to know.
    ///
    /// The card **is** the claim. `activeRun(cardID:)` answers with this run for
    /// its whole life, so `BoardService.proposeMove` — which reads that same
    /// query — returns `.blocked(.runAlreadyInFlight)` while it goes. That is
    /// what closes the card's write window in both directions, and it is why an
    /// appraisal run carries a `cardID` rather than a synthetic analysis.
    ///
    /// A run with no card cannot claim one: an analysis run is refused here
    /// rather than inserted unguarded, because "no card to hold" is not "the
    /// card is free".
    public func claimCardForRun(_ run: SkillRun) async throws -> Bool {
        guard let cardID = run.cardID else { return false }
        return try await requireWriter().write { db in
            let held = try SkillRun
                .filter(SkillRun.Columns.cardID == cardID.databaseKey)
                .filter(Self.activeStates.contains(SkillRun.Columns.state))
                .fetchCount(db)
            guard held == 0 else { return false }
            try run.insert(db)
            return true
        }
    }

    /// The run currently holding a card, if any.
    public func activeRun(cardID: UUID) async throws -> SkillRun? {
        try await reader.read { db in
            try SkillRun
                .filter(SkillRun.Columns.cardID == cardID.databaseKey)
                .filter(Self.activeStates.contains(SkillRun.Columns.state))
                .order(SkillRun.Columns.createdAt.desc)
                .fetchOne(db)
        }
    }

    /// The run holding each of these cards, for a whole page in one query.
    ///
    /// A card missing from the answer has no run holding it — that is the only
    /// thing its absence may be read to mean. Asked one card at a time this is
    /// a round trip per row, and the caller that skips it altogether reports
    /// every held card as movable, which is the more expensive mistake.
    public func activeRuns(cardIDs: [UUID]) async throws -> [UUID: SkillRun] {
        guard !cardIDs.isEmpty else { return [:] }
        let keys = cardIDs.map(\.databaseKey)
        let runs = try await reader.read { db in
            try SkillRun
                .filter(keys.contains(SkillRun.Columns.cardID))
                .filter(Self.activeStates.contains(SkillRun.Columns.state))
                .order(SkillRun.Columns.createdAt.desc)
                .fetchAll(db)
        }
        // Newest first, so the first row for a card wins — the same run
        // `activeRun(cardID:)` answers with on its own.
        //
        // `compactMap` rather than a force-unwrap: `cardID` is nullable since an
        // analysis run has no card. The `contains` filter above already excludes
        // those rows in SQL, so nothing is dropped here in practice — this is
        // the type admitting what the query already guarantees.
        return Dictionary(
            runs.compactMap { run in run.cardID.map { ($0, run) } },
            uniquingKeysWith: { newest, _ in newest }
        )
    }

    /// The most recent runs across the whole board, newest first.
    ///
    /// A second, shallower path than `runs(cardID:)`, which the inspector uses
    /// and which is right to load one card deeply. This one exists because an
    /// overview cannot ask a question per row: costs and verdicts already in the
    /// database were reachable one selected card at a time, which is what made
    /// the missing cost view architectural rather than cosmetic.
    ///
    /// A run missing from the answer is outside the limit — that is the only
    /// thing its absence may be read to mean.
    public func recentRuns(limit: Int = 50) async throws -> [SkillRun] {
        try await reader.read { db in
            try SkillRun
                .order(SQLColumn("createdAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// One repository's runs since a date, newest first.
    public func runs(repoID: UUID, since: Date, limit: Int = 200) async throws -> [SkillRun] {
        try await reader.read { db in
            try SkillRun
                .filter(SkillRun.Columns.repoID == repoID.databaseKey)
                .filter(SQLColumn("createdAt") >= since)
                .order(SQLColumn("createdAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Every run that was mid-flight when the app stopped. The launch sweep
    /// resolves each one against `gh` rather than trusting its recorded state.
    public func nonTerminalRuns() async throws -> [SkillRun] {
        try await reader.read { db in
            try SkillRun
                .filter(Self.activeStates.contains(SkillRun.Columns.state))
                .order(SkillRun.Columns.createdAt)
                .fetchAll(db)
        }
    }

    public func observeRuns(cardID: UUID) -> AsyncValueObservation<[SkillRun]> {
        ValueObservation
            .tracking { db in
                try SkillRun
                    .filter(SkillRun.Columns.cardID == cardID.databaseKey)
                    .order(SkillRun.Columns.createdAt.desc)
                    .fetchAll(db)
            }
            .removeDuplicates()
            .values(in: reader)
    }

    private static let activeStates = RunState.allCases.filter(\.isActive).map(\.rawValue)

    // MARK: - Analyses

    public func saveAnalysis(_ analysis: Analysis) async throws {
        try await requireWriter().write { db in try analysis.save(db) }
    }

    /// Saves an analysis and its queued runs in one transaction — the same
    /// shape as `commitMove`: either every row lands or none does. A crash
    /// between two separate writes here could leave an `Analysis` with fewer
    /// `SkillRun` rows than it was queued with, and nothing walks `analysis.angles`
    /// against its runs to notice; one transaction is what rules that out rather
    /// than merely making it unlikely.
    public func saveAnalysis(_ analysis: Analysis, runs: [SkillRun]) async throws {
        try await requireWriter().write { db in
            try analysis.save(db)
            for run in runs { try run.insert(db) }
        }
    }

    public func analysis(id: UUID) async throws -> Analysis? {
        try await reader.read { db in try Analysis.fetchOne(db, key: id.databaseKey) }
    }

    public func analyses(repoID: UUID? = nil, limit: Int = 50) async throws -> [Analysis] {
        try await reader.read { db in
            var request = Analysis.all()
            if let repoID {
                request = request.filter(Analysis.Columns.repoID == repoID.databaseKey)
            }
            return try request.order(Analysis.Columns.createdAt.desc).limit(limit).fetchAll(db)
        }
    }

    /// Every run of one analysis, oldest first — the order the window lists them.
    public func runs(analysisID: UUID) async throws -> [SkillRun] {
        try await reader.read { db in
            try SkillRun
                .filter(SkillRun.Columns.analysisID == analysisID.databaseKey)
                .order(SkillRun.Columns.createdAt)
                .fetchAll(db)
        }
    }

    /// Analysis runs still in flight for a repo. The dedupe key `(repoID, angle)`
    /// is checked against this.
    public func activeAnalysisRuns(repoID: UUID) async throws -> [SkillRun] {
        try await reader.read { db in
            try SkillRun
                .filter(SkillRun.Columns.repoID == repoID.databaseKey)
                .filter(SkillRun.Columns.analysisID != nil)
                .filter(Self.activeStates.contains(SkillRun.Columns.state))
                .fetchAll(db)
        }
    }

    // MARK: - Proposals

    public func saveProposals(_ proposals: [StoryProposal]) async throws {
        try await requireWriter().write { db in
            for proposal in proposals { try proposal.save(db) }
        }
    }

    public func saveProposal(_ proposal: StoryProposal) async throws {
        try await saveProposals([proposal])
    }

    /// Moves a proposal along one ``ProposalClaim``, atomically: `true` means
    /// this call won, `false` means it does not exist or was not in the status
    /// the claim moves out of — because another caller decided it first, in
    /// either direction, or because it has already produced a card.
    ///
    /// `AnalysisService` is a reentrant actor — concurrent `accept`/`reject`
    /// calls for the same id (a double-tap, an MCP retry, or an ordinary
    /// double-click on *Reject* and *Accept* sitting 6pt apart over one
    /// multi-selection) can each be past a `fetch → check .proposed` read
    /// before any of them has written. A single conditional `UPDATE` is what
    /// makes that safe: SQLite serializes every write, so only the first caller
    /// whose `UPDATE` still finds the expected status changes anything, and
    /// every other caller — including one deciding the *opposite* way — sees
    /// zero rows changed rather than a stale read it has no way to know is
    /// stale. This is the same reason a losing `reject` can never wipe an
    /// already-`.accepted` row's `acceptedCardID`: it never issues an
    /// unconditional write at all.
    ///
    /// ⛔ **`restore` had to arrive inside this statement, not beside it.** The
    /// obvious undo — read the row, check it is `.rejected`, write `.proposed`
    /// — is character for character the fetch/check/write this method exists to
    /// replace, and it reintroduces the same race one direction further round:
    /// a restore that loses to a concurrent accept would put a proposal whose
    /// card already exists back on the triage list. Because the claim carries
    /// both ends of its transition, it stays one statement (#292).
    ///
    /// ⚠️ **`acceptedCardID IS NULL` is redundant for `accept` and `reject` and
    /// load-bearing for `restore`** — which is exactly why it is written once,
    /// here, rather than per claim. Both of the first two move *out of*
    /// `.proposed`, a status no reachable path leaves a card id on, so the
    /// predicate can only ever be true for them; `restore` moves out of
    /// `.rejected`, where a card id genuinely can sit, and letting that row
    /// through is how one story grows two Backlog cards. A fourth claim
    /// inherits the guard instead of having to remember it.
    public func claimProposal(id: UUID, _ claim: ProposalClaim) async throws -> Bool {
        try await requireWriter().write { db in
            try db.execute(
                sql: #"""
                    UPDATE "storyProposal" SET "status" = ?
                     WHERE "id" = ? AND "status" = ? AND "acceptedCardID" IS NULL
                    """#,
                arguments: [claim.to.rawValue, id.databaseKey, claim.from.rawValue]
            )
            return db.changesCount > 0
        }
    }

    public func proposal(id: UUID) async throws -> StoryProposal? {
        try await reader.read { db in try StoryProposal.fetchOne(db, key: id.databaseKey) }
    }

    /// Every filter is `nil`-means-unfiltered and they compose, so
    /// `proposals(runID:)` answers "what did *this lens* land" — which is what
    /// a repeat harvest has to know before it writes anything (#330).
    public func proposals(
        analysisID: UUID? = nil,
        repoID: UUID? = nil,
        runID: UUID? = nil,
        status: ProposalStatus? = nil,
        limit: Int = 500
    ) async throws -> [StoryProposal] {
        try await reader.read { db in
            try Self.proposalQuery(
                analysisID: analysisID, repoID: repoID, runID: runID, status: status
            )
            .limit(limit)
            .fetchAll(db)
        }
    }

    private static func proposalQuery(
        analysisID: UUID?, repoID: UUID?, runID: UUID?, status: ProposalStatus?
    ) -> QueryInterfaceRequest<StoryProposal> {
        var request = StoryProposal.all()
        if let analysisID {
            request = request.filter(StoryProposal.Columns.analysisID == analysisID.databaseKey)
        }
        if let repoID {
            request = request.filter(StoryProposal.Columns.repoID == repoID.databaseKey)
        }
        if let runID {
            request = request.filter(StoryProposal.Columns.runID == runID.databaseKey)
        }
        if let status {
            request = request.filter(StoryProposal.Columns.status == status.rawValue)
        }
        return request.order(StoryProposal.Columns.createdAt)
    }

    /// Live proposals for the analysis window: they arrive run by run, so the
    /// list fills in as each angle lands rather than after the last one.
    public func observeProposals(analysisID: UUID) -> AsyncValueObservation<[StoryProposal]> {
        ValueObservation
            .tracking { db in
                try Self.proposalQuery(
                    analysisID: analysisID, repoID: nil, runID: nil, status: nil
                ).fetchAll(db)
            }
            .removeDuplicates()
            .values(in: reader)
    }

    // MARK: - Dismissals

    /// The one read of `dismissedExternal`, in the one shape that keeps
    /// everything the table stores.
    ///
    /// `repoID: nil` is every repository — the meaning *All repositories* has on
    /// the board's picker — and an id that matches nothing is an empty list
    /// rather than the whole table.
    ///
    /// A row whose `kind` does not decode is dropped, which is what `dismissals`
    /// has always done: the column is a `String` and the enum is closed, so a
    /// value written by a newer build names a kind this one cannot act on.
    /// Dropping it costs a suppression its row in the list; keeping it would
    /// need a `DismissedItem` that cannot say what it is.
    ///
    /// Ordered through ``DismissalDigest/rows(_:repoID:)`` rather than by a
    /// `SQL ORDER BY`, so the sort the reader sees is decided **once**, in the
    /// pure type that is tested for being total. The filter has already happened
    /// in SQL, hence `repoID: nil` here.
    public func dismissedItems(repoID: UUID?) async throws -> [DismissedItem] {
        try await reader.read { db in
            var request = DismissalRecord.all()
            if let repoID { request = request.filter(SQLColumn("repoID") == repoID.databaseKey) }
            return Self.items(try request.fetchAll(db))
        }
    }

    /// The importer's view: the keys, and nothing else.
    ///
    /// A **projection** of ``dismissedItems(repoID:)`` since #334, not a second
    /// SELECT over the same table. `GitHubImporter.plan` is still its only
    /// caller and still needs only the keys; what changed is that the reader's
    /// query and the importer's cannot drift apart, because there is one query.
    public func dismissals(repoID: UUID) async throws -> Set<ExternalRef> {
        Set(try await dismissedItems(repoID: repoID).map(\.ref))
    }

    /// Idempotent: dismissing something already dismissed is not an error, and
    /// the user may well delete a card a refresh brought back.
    public func dismiss(_ ref: ExternalRef, repoID: UUID, now: Date = Date()) async throws {
        try await requireWriter().write { db in
            try DismissalRecord(
                repoID: repoID, kind: ref.kind.rawValue,
                number: ref.number, dismissedAt: now
            ).upsert(db)
        }
    }

    /// Deletes **exactly one** suppression — the whole point of #334, against a
    /// board whose only undo was ``clearDismissals(repoID:)``.
    ///
    /// Keyed on all three columns of the primary key. A delete keyed on the
    /// number alone would take issue 5 *and* pull request 5, which is the pair a
    /// single card writes; keyed without the repository it would reach into
    /// every repository at once, which is the bulk act this method exists to
    /// avoid.
    ///
    /// Idempotent, matching ``dismiss(_:repoID:now:)`` from the other side: a
    /// row the last refresh already brought back is a row *Restore* can be
    /// pressed on twice.
    ///
    /// ⚠️ This creates **no card**. The importer creates cards; a second path
    /// that inserted one would be the second write path `BoardService` exists to
    /// prevent. The row goes, and the next refresh brings the card back.
    public func undismiss(_ ref: ExternalRef, repoID: UUID) async throws {
        _ = try await requireWriter().write { db in
            try DismissalRecord
                .filter(SQLColumn("repoID") == repoID.databaseKey)
                .filter(SQLColumn("kind") == ref.kind.rawValue)
                .filter(SQLColumn("number") == ref.number)
                .deleteAll(db)
        }
    }

    public func clearDismissals(repoID: UUID) async throws {
        _ = try await requireWriter().write { db in
            try DismissalRecord.filter(SQLColumn("repoID") == repoID.databaseKey).deleteAll(db)
        }
    }

    /// Every suppression, live.
    ///
    /// Its own observation for the reason `observePRStatuses` has one: nothing
    /// about a dismissal touches a card row, so a figure refreshed off the card
    /// observation would follow a restore exactly never. It is what makes the
    /// status-bar figure a reading of the table rather than of the last import
    /// summary — a stale count cannot outlive the fact it reports.
    public func observeDismissals() -> AsyncValueObservation<[DismissedItem]> {
        ValueObservation
            .tracking { db in Self.items(try DismissalRecord.fetchAll(db)) }
            .removeDuplicates()
            .values(in: reader)
    }

    /// Rows to items, in one place, so the three readers above cannot disagree
    /// about what a row means or what order they arrive in.
    ///
    /// The ordering matters to `removeDuplicates()` as much as to the eye: two
    /// deliveries of an unchanged table must compare equal, and an array whose
    /// order is SQLite's rowid order is only accidentally stable across a delete
    /// and a re-insert.
    private static func items(_ rows: [DismissalRecord]) -> [DismissedItem] {
        let items = rows.compactMap { row -> DismissedItem? in
            guard let kind = ExternalKind(rawValue: row.kind) else { return nil }
            return DismissedItem(
                repoID: row.repoID, ref: ExternalRef(kind: kind, number: row.number),
                dismissedAt: row.dismissedAt)
        }
        return DismissalDigest.rows(items, repoID: nil)
    }

    // MARK: - Audit

    public func audits(cardID: UUID, limit: Int = 100) async throws -> [MoveAudit] {
        try await reader.read { db in
            try MoveAudit
                .filter(SQLColumn("cardID") == cardID.databaseKey)
                .order(SQLColumn("at").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Every move since a moment, oldest first.
    ///
    /// Ascending, unlike `audits(cardID:)` next door, and the difference is not
    /// cosmetic: this feeds a follower that has a watermark and wants what it
    /// has not seen yet, in the order it happened. Descending would hand it the
    /// newest `limit` and silently drop the middle of a busy interval — the
    /// same shape of defect as a page that does not say it was cut.
    ///
    /// `since` is exclusive, so passing back the `at` of the last row you
    /// handled cannot replay it. Notifications are the caller this exists for,
    /// and a replayed audit is a duplicate banner for something already read.
    public func moveAudits(since: Date, limit: Int = 200) async throws -> [MoveAudit] {
        try await reader.read { db in
            try MoveAudit
                .filter(SQLColumn("at") > since)
                .order(SQLColumn("at").asc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// The same query, observed.
    ///
    /// Reads the audit trail rather than watching cards change, because the
    /// audit is the only place that records *why* a card moved. Watching the
    /// card table would see a column change and have to guess whether a person
    /// or the board caused it — and guessing there is exactly how a user's own
    /// drag turns into a notification telling them what they just did.
    public func observeMoveAudits(since: Date, limit: Int = 200) -> AsyncValueObservation<[MoveAudit]> {
        ValueObservation
            .tracking { db in
                try MoveAudit
                    .filter(SQLColumn("at") > since)
                    .order(SQLColumn("at").asc)
                    .limit(limit)
                    .fetchAll(db)
            }
            .removeDuplicates()
            .values(in: reader)
    }

    // MARK: - Seams for the tests, deliberately not public
    //
    // `internal`, so `@testable` reaches them and neither the app nor the MCP
    // helper can. Production records an audit in exactly one place — inside
    // `move`'s single transaction, beside the column it explains — and a
    // *public* writer here would be a standing invitation to record a move that
    // never happened, which is the audit-trail version of a second write path.
    // The query above still has to be provable against arbitrary `at` and
    // `origin` values that the compound write cannot be made to produce.

    func insertMoveAudit(_ audit: MoveAudit) async throws {
        guard let writer else { throw StoreError.readOnly }
        try await writer.write { db in try audit.insert(db) }
    }

    /// The indexes on a table, by name.
    ///
    /// A migration that only creates an index leaves no trace in any row, so
    /// this is the only way a test can show it ran at all.
    func indexNames(on table: String) async throws -> [String] {
        try await reader.read { db in try db.indexes(on: table).map(\.name) }
    }

    // MARK: - The one compound write

    /// Moves a card and, when the move triggers a skill, records the run — in a
    /// single transaction.
    ///
    /// Either all three rows land or none do. The run is left `.queued`; the
    /// scheduler is handed the id only *after* the transaction commits, so a
    /// crash in between leaves a queued run for the launch sweep to pick up
    /// rather than a card that moved with nothing to show for it.
    public func commitMove(
        card: Card,
        to column: ElliotModel.Column,
        orderIndex: Double,
        origin: MoveOrigin,
        run: SkillRun?,
        now: Date = Date()
    ) async throws {
        try await requireWriter().write { db in
            var updated = card
            let from = card.column
            updated.column = column
            updated.orderIndex = orderIndex
            updated.columnEnteredAt = now
            updated.updatedAt = now
            if run != nil { updated.lastError = nil }
            try updated.update(db)

            if let run { try run.insert(db) }

            let audit = MoveAudit(
                cardID: card.id,
                from: from,
                to: column,
                origin: origin,
                runID: run?.id,
                at: now
            )
            try audit.insert(db)
        }
    }
}

public enum StoreError: Error, LocalizedError {
    case readOnly
    /// Opened read-only, and no migration has ever run on the file.
    case schemaMissing
    /// Opened read-only, and the file names migrations this build does not have.
    case schemaTooNew

    public var errorDescription: String? {
        switch self {
        case .readOnly:
            "Elliot is not running, so the board cannot be changed from here."
        case .schemaMissing:
            "Elliot's database has not been set up yet. Open Elliot.app once."
        case .schemaTooNew:
            """
            Elliot's database was written by a newer version of Elliot than this \
            helper. Update the helper rather than reading the board with it.
            """
        }
    }
}
