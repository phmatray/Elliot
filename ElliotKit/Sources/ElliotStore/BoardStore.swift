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

    // MARK: - Settings

    private static let layoutKey = "repositoryLayout"

    public func layout() async throws -> RepoTreeLayout? {
        let json = try await reader.read { db in
            try String.fetchOne(
                db, sql: #"SELECT "value" FROM "setting" WHERE "key" = ?"#,
                arguments: [Self.layoutKey])
        }
        guard let data = json?.data(using: .utf8) else { return nil }
        return try JSONDecoder().decode(RepoTreeLayout.self, from: data)
    }

    public func saveLayout(_ layout: RepoTreeLayout) async throws {
        let json = String(decoding: try JSONEncoder().encode(layout), as: UTF8.self)
        try await requireWriter().write { db in
            try db.execute(
                sql: #"""
                    INSERT INTO "setting" ("key", "value") VALUES (?, ?)
                    ON CONFLICT("key") DO UPDATE SET "value" = excluded."value"
                    """#,
                arguments: [Self.layoutKey, json])
        }
    }

    // MARK: - Cards

    public func saveCard(_ card: Card) async throws {
        var card = card
        card.updatedAt = Date()
        try await requireWriter().write { [card] db in try card.save(db) }
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

    /// Live cards for the board. Only fires on an actual change.
    public func observeCards(repoID: UUID? = nil) -> AsyncValueObservation<[Card]> {
        ValueObservation
            .tracking { db in
                try Self.cardQuery(repoID: repoID, column: nil, limit: nil).fetchAll(db)
            }
            .removeDuplicates()
            .values(in: reader)
    }

    public func observeRepos() -> AsyncValueObservation<[Repo]> {
        ValueObservation
            .tracking { db in try Repo.order(SQLColumn("displayName")).fetchAll(db) }
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
        return Dictionary(runs.map { ($0.cardID, $0) }, uniquingKeysWith: { newest, _ in newest })
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
