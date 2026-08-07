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

    // MARK: - Repos

    public func saveRepo(_ repo: Repo) async throws {
        try await requireWriter().write { db in try repo.save(db) }
    }

    public func deleteRepo(id: UUID) async throws {
        _ = try await requireWriter().write { db in try Repo.deleteOne(db, key: id.databaseKey) }
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

    /// Flips a proposal from `.proposed` to `status`, atomically: `true` means
    /// this call won, `false` means it does not exist or another caller
    /// already decided it first — accepted or rejected, in either direction.
    ///
    /// `AnalysisService` is a reentrant actor — concurrent `accept`/`reject`
    /// calls for the same id (a double-tap, an MCP retry, or — once Task 13's
    /// Analysis window ships — an ordinary double-click on *Reject* and
    /// *→ Backlog* sitting side by side over one multi-selection) can each be
    /// past a `fetch → check .proposed` read before any of them has written.
    /// A single conditional `UPDATE` is what makes that safe: SQLite
    /// serializes every write, so only the first caller whose `UPDATE` still
    /// finds `status = 'proposed'` changes anything, and every other caller —
    /// including one deciding the *opposite* way — sees zero rows changed
    /// rather than a stale read it has no way to know is stale. This is the
    /// same reason a losing `reject` can never wipe an already-`.accepted`
    /// row's `acceptedCardID`: it never issues an unconditional write at all.
    public func claimProposal(id: UUID, to status: ProposalStatus) async throws -> Bool {
        try await requireWriter().write { db in
            try db.execute(
                sql: #"""
                    UPDATE "storyProposal" SET "status" = ? WHERE "id" = ? AND "status" = ?
                    """#,
                arguments: [status.rawValue, id.databaseKey, ProposalStatus.proposed.rawValue]
            )
            return db.changesCount > 0
        }
    }

    public func proposal(id: UUID) async throws -> StoryProposal? {
        try await reader.read { db in try StoryProposal.fetchOne(db, key: id.databaseKey) }
    }

    public func proposals(
        analysisID: UUID? = nil,
        repoID: UUID? = nil,
        status: ProposalStatus? = nil,
        limit: Int = 500
    ) async throws -> [StoryProposal] {
        try await reader.read { db in
            try Self.proposalQuery(analysisID: analysisID, repoID: repoID, status: status)
                .limit(limit)
                .fetchAll(db)
        }
    }

    private static func proposalQuery(
        analysisID: UUID?, repoID: UUID?, status: ProposalStatus?
    ) -> QueryInterfaceRequest<StoryProposal> {
        var request = StoryProposal.all()
        if let analysisID {
            request = request.filter(StoryProposal.Columns.analysisID == analysisID.databaseKey)
        }
        if let repoID {
            request = request.filter(StoryProposal.Columns.repoID == repoID.databaseKey)
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
                try Self.proposalQuery(analysisID: analysisID, repoID: nil, status: nil).fetchAll(db)
            }
            .removeDuplicates()
            .values(in: reader)
    }

    // MARK: - Dismissals

    public func dismissals(repoID: UUID) async throws -> Set<ExternalRef> {
        try await reader.read { db in
            let rows = try DismissalRecord
                .filter(SQLColumn("repoID") == repoID.databaseKey)
                .fetchAll(db)
            return Set(
                rows.compactMap { row in
                    ExternalKind(rawValue: row.kind).map { ExternalRef(kind: $0, number: row.number) }
                })
        }
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

    public func clearDismissals(repoID: UUID) async throws {
        _ = try await requireWriter().write { db in
            try DismissalRecord.filter(SQLColumn("repoID") == repoID.databaseKey).deleteAll(db)
        }
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
