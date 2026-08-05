import ElliotModel
import Foundation
import GRDB
import Testing

@testable import ElliotStore

private let then = Date(timeIntervalSince1970: 1_700_000_000)

/// A directory that goes away with the test.
private struct Scratch: ~Copyable {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elliot-schema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var database: URL { url.appendingPathComponent("elliot.sqlite") }

    deinit { try? FileManager.default.removeItem(at: url) }
}

private func repo(_ displayName: String = "Elliot") -> Repo {
    Repo(
        path: "/tmp/repo-\(UUID().uuidString)",
        nameWithOwner: "phmatray/\(displayName)",
        displayName: displayName
    )
}

private func card(
    repoID: UUID,
    title: String = "Run log",
    column: ElliotModel.Column = .backlog,
    orderIndex: Double = 1024,
    idempotencyKey: String? = nil
) -> Card {
    Card(
        repoID: repoID,
        title: title,
        column: column,
        orderIndex: orderIndex,
        columnEnteredAt: then,
        createdAt: then,
        updatedAt: then,
        idempotencyKey: idempotencyKey
    )
}

private func run(cardID: UUID, repoID: UUID, state: RunState = .queued) -> SkillRun {
    SkillRun(
        cardID: cardID,
        repoID: repoID,
        kind: .createIssue,
        prompt: "/create-issue",
        cwd: "/tmp/repo",
        state: state,
        logPath: "/tmp/log.ndjson",
        stderrPath: "/tmp/log.stderr.log",
        createdAt: then
    )
}

/// Puts a database back to the schema an older Elliot left behind.
///
/// Raw SQL because there is no other way to get one: the current record types
/// carry `idempotencyKey`, so nothing above this line can write a row into a
/// table that predates the column. The point of going backwards is that the
/// only migration that will ever run in the field runs over rows that are
/// already there, and a file born current never exercises it.
private func rewindToV1(_ url: URL) throws {
    let queue = try DatabaseQueue(path: url.path)
    try queue.write { db in
        try db.execute(sql: #"DROP INDEX "card_on_idempotencyKey""#)
        try db.execute(sql: #"ALTER TABLE "card" DROP COLUMN "idempotencyKey""#)
        try db.execute(
            sql: #"DELETE FROM "grdb_migrations" WHERE "identifier" = 'v2_cardIdempotencyKey'"#
        )
    }
}

/// Claims a migration this build has never heard of — what a file written by a
/// newer Elliot looks like to an older helper.
private func stampMigration(_ identifier: String, at url: URL) throws {
    let queue = try DatabaseQueue(path: url.path)
    try queue.write { db in
        try db.execute(
            sql: #"INSERT INTO "grdb_migrations" ("identifier") VALUES (?)"#,
            arguments: [identifier]
        )
    }
}

private func columnNames(of table: String, at url: URL) throws -> Set<String> {
    let queue = try DatabaseQueue(path: url.path)
    return try queue.read { db in
        Set(try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").compactMap { $0["name"] as String? })
    }
}

@Suite("Upgrading a board that already holds work")
struct SchemaUpgradeTests {

    @Test("A database written by the previous Elliot keeps its rows through the upgrade")
    func upgradeOverExistingRows() async throws {
        let scratch = try Scratch()
        let elliot = repo()
        let kept = card(repoID: elliot.id, title: "Written before the upgrade")

        do {
            let old = try BoardStore.open(at: scratch.database)
            try await old.saveRepo(elliot)
            try await old.saveCard(kept)
            try await old.saveRun(run(cardID: kept.id, repoID: elliot.id))
        }
        try rewindToV1(scratch.database)
        // The rewind has to have actually happened, or this test upgrades a
        // database that was already current and proves nothing.
        #expect(!(try columnNames(of: "card", at: scratch.database).contains("idempotencyKey")))

        let upgraded = try BoardStore.open(at: scratch.database)

        let card = try #require(try await upgraded.card(id: kept.id))
        #expect(card.title == "Written before the upgrade")
        // Absent from the old file, so nil is the truth rather than a default:
        // nothing could have written a value the column did not exist to hold.
        #expect(card.idempotencyKey == nil)
        #expect(try await upgraded.runCount() == 1)
        #expect(try await upgraded.repos().count == 1)
    }

    @Test("The upgraded index rejects a second card with the same key, and no card without one")
    func uniqueIndexAfterUpgrade() async throws {
        let scratch = try Scratch()
        let elliot = repo()
        do {
            let old = try BoardStore.open(at: scratch.database)
            try await old.saveRepo(elliot)
            // Three keyless cards, which is every card the UI ever makes. SQLite
            // counts NULLs as distinct in a unique index; if it did not, the
            // upgrade would fail on the second row of any real board.
            for index in 0..<3 {
                try await old.saveCard(card(repoID: elliot.id, orderIndex: Double(index)))
            }
        }
        try rewindToV1(scratch.database)

        let store = try BoardStore.open(at: scratch.database)
        #expect(try await store.cards().count == 3)

        try await store.saveCard(card(repoID: elliot.id, orderIndex: 9, idempotencyKey: "K"))
        await #expect(throws: (any Error).self) {
            try await store.saveCard(card(repoID: elliot.id, orderIndex: 10, idempotencyKey: "K"))
        }
        #expect(try await store.card(idempotencyKey: "K")?.orderIndex == 9)
        #expect(try await store.card(idempotencyKey: "not used") == nil)
    }

    // MARK: - What the helper refuses at the door

    @Test("A file that names a migration this build does not have is refused, not read")
    func schemaTooNewIsRefused() async throws {
        let scratch = try Scratch()
        do {
            let store = try BoardStore.open(at: scratch.database)
            try await store.saveRepo(repo())
        }
        try stampMigration("v3_from_the_future", at: scratch.database)

        #expect(throws: StoreError.schemaTooNew) {
            _ = try BoardStore.openReadOnly(at: scratch.database)
        }
    }

    @Test("A readable file that is not a board is refused with the reason")
    func schemaMissingIsRefused() throws {
        let scratch = try Scratch()
        let queue = try DatabaseQueue(path: scratch.database.path)
        try queue.write { db in try db.execute(sql: "CREATE TABLE notes(text)") }

        #expect(throws: StoreError.schemaMissing) {
            _ = try BoardStore.openReadOnly(at: scratch.database)
        }
        // The message is the whole point: it names the action that fixes it, and
        // that action is not the one "Elliot is not running" would suggest.
        #expect(StoreError.schemaMissing.errorDescription?.contains("Open Elliot.app") == true)
        #expect(StoreError.schemaTooNew.errorDescription?.contains("Update the helper") == true)
    }
}

@Suite("Reading a page of the board")
struct BoardPagingTests {

    @Test("Cards spanning repositories come back by repository, then board column")
    func crossRepoOrder() async throws {
        // `orderIndex` restarts at 1024 in every (repo, column) pair, so it
        // cannot order a listing that spans them — and a limit then cuts an
        // arbitrary set out of whatever SQLite found convenient.
        let store = try BoardStore.inMemory()
        let zulu = repo("Zulu"), alpha = repo("Alpha")
        try await store.saveRepo(zulu)
        try await store.saveRepo(alpha)

        try await store.saveCard(card(repoID: zulu.id, title: "Z-todo", column: .todo))
        try await store.saveCard(card(repoID: zulu.id, title: "Z-backlog", column: .backlog))
        try await store.saveCard(card(repoID: alpha.id, title: "A-done", column: .done))
        try await store.saveCard(card(repoID: alpha.id, title: "A-backlog-2", column: .backlog, orderIndex: 2048))
        try await store.saveCard(card(repoID: alpha.id, title: "A-backlog-1", column: .backlog, orderIndex: 1024))

        let titles = try await store.cards().map(\.title)
        #expect(titles == ["A-backlog-1", "A-backlog-2", "A-done", "Z-backlog", "Z-todo"])

        // Board order, not alphabetical on the raw value — `done` sorts after
        // `backlog` here, where a plain string sort puts it first.
        #expect(titles.firstIndex(of: "A-backlog-1")! < titles.firstIndex(of: "A-done")!)
    }

    @Test("A limit cuts the head of that order, in SQL")
    func limitCutsTheOrderedHead() async throws {
        let store = try BoardStore.inMemory()
        let alpha = repo("Alpha"), zulu = repo("Zulu")
        try await store.saveRepo(alpha)
        try await store.saveRepo(zulu)
        for index in 0..<4 {
            try await store.saveCard(
                card(repoID: zulu.id, title: "Z\(index)", orderIndex: Double(index))
            )
            try await store.saveCard(
                card(repoID: alpha.id, title: "A\(index)", orderIndex: Double(index))
            )
        }

        #expect(try await store.cards(limit: 3).map(\.title) == ["A0", "A1", "A2"])
        // Cut, but the count of what was cut from is not.
        #expect(try await store.cardCount() == 8)
        #expect(try await store.cardCount(repoID: alpha.id) == 4)
        #expect(try await store.cardCount(column: .todo) == 0)
    }

    @Test("The runs holding a page of cards are found in one query")
    func activeRunsForAPage() async throws {
        let store = try BoardStore.inMemory()
        let elliot = repo()
        try await store.saveRepo(elliot)
        let held = card(repoID: elliot.id, title: "Held")
        let free = card(repoID: elliot.id, title: "Free", orderIndex: 2048)
        try await store.saveCard(held)
        try await store.saveCard(free)

        let running = run(cardID: held.id, repoID: elliot.id, state: .running)
        try await store.saveRun(running)
        // A finished run holds nothing, and must not be reported as if it did.
        try await store.saveRun(run(cardID: free.id, repoID: elliot.id, state: .succeeded))

        let active = try await store.activeRuns(cardIDs: [held.id, free.id])
        #expect(active[held.id]?.id == running.id)
        #expect(active[free.id] == nil)
        // Absence is the only thing an absent card may be read to mean, so a
        // card nobody asked about must not appear either.
        #expect(try await store.activeRuns(cardIDs: []).isEmpty)

        #expect(try await store.runCount() == 2)
        #expect(try await store.runCount(cardID: held.id) == 1)
        #expect(try await store.runCount(cardID: UUID()) == 0)
    }
}
