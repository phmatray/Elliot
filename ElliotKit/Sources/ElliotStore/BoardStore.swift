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
    /// rather than rewrite a database it does not own.
    public static func openReadOnly(at url: URL? = nil) throws -> BoardStore {
        let path = (url ?? StoreLocation.databaseURL).path
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.readonly = true
        let queue = try DatabaseQueue(path: path, configuration: config)
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

    public func cards(repoID: UUID? = nil, column: ElliotModel.Column? = nil) async throws -> [Card] {
        try await reader.read { db in try Self.cardQuery(repoID: repoID, column: column).fetchAll(db) }
    }

    private static func cardQuery(repoID: UUID?, column: ElliotModel.Column?) -> QueryInterfaceRequest<Card> {
        var request = Card.all()
        if let repoID {
            request = request.filter(Card.Columns.repoID == repoID.databaseKey)
        }
        if let column {
            request = request.filter(Card.Columns.column == column.rawValue)
        }
        return request.order(Card.Columns.orderIndex)
    }

    /// Live cards for the board. Only fires on an actual change.
    public func observeCards(repoID: UUID? = nil) -> AsyncValueObservation<[Card]> {
        ValueObservation
            .tracking { db in try Self.cardQuery(repoID: repoID, column: nil).fetchAll(db) }
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
            var request = SkillRun.all()
            if let cardID {
                request = request.filter(SkillRun.Columns.cardID == cardID.databaseKey)
            }
            if let repoID {
                request = request.filter(SkillRun.Columns.repoID == repoID.databaseKey)
            }
            return try request.order(SkillRun.Columns.createdAt.desc).limit(limit).fetchAll(db)
        }
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

    public var errorDescription: String? {
        switch self {
        case .readOnly:
            "Elliot is not running, so the board cannot be changed from here."
        }
    }
}
