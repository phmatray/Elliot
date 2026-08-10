import ElliotModel
import Foundation
import GRDB
import Testing

@testable import ElliotStore

/// Apart from `BoardStoreTests` for the reason `MigrationsTests` is: it drives
/// the migrator directly and so needs `import GRDB`, whose `Column` collides
/// with the board's five columns.
@Suite("A repository row written before the method column")
struct RepoMethodMigrationTests {

    /// Named once. When the next migration lands on top of this one, the tests
    /// below must keep asking about the schema *before* the method column rather
    /// than silently starting to test the newest thing instead.
    ///
    /// ⚠️ It has already happened, which is why nothing here spells a number any
    /// more. The method column shipped as `v11_repoMethodID`, sat unmerged while
    /// four migrations landed on `main`, and became `v15_repoMethodID`; this
    /// constant moved from `v10_repoPreflight` to `v14_repoLabelPolicy` with it.
    /// The helper below was called `preV11Database`, and a name carrying the
    /// number is a name that rots — it is `databaseBeforeTheMethodColumn` now,
    /// after what it *is* rather than after where it once sat.
    private static let migrationBeforeMethod = "v14_repoLabelPolicy"

    /// A database migrated only as far as the release before this column, with
    /// one repository row seeded through raw SQL — the record type knows about a
    /// column these fixtures must not have.
    private func databaseBeforeTheMethodColumn() throws
        -> (url: URL, repoID: String, remove: () -> Void)
    {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elliot-pre-method-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try Migrations.migrator.migrate(queue, upTo: Self.migrationBeforeMethod)
        let repoID = UUID().uuidString.uppercased()
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
        }
        try queue.close()
        return (url, repoID, { try? FileManager.default.removeItem(at: url) })
    }

    /// The trap this field's whole shape exists to avoid, measured rather than
    /// trusted.
    ///
    /// `BoardStore.openReadOnly` never migrates: it accepts a database *older*
    /// than the build reading it, which is what keeps the MCP helper answering
    /// between a new bundle landing and the app next launching. Swift's
    /// synthesised decoder **ignores a property's default value** — it emits
    /// `decode(_:forKey:)`, not `decodeIfPresent` — so `methodID: String =
    /// "ai-migration-kit"` would compile, read correctly everywhere the app
    /// looks, and throw `keyNotFound` here, refusing **every** repository in
    /// exactly the window `openReadOnly` is there to serve. This is the class of
    /// regression `OlderDatabaseTests` exists to catch.
    @Test("A pre-method database still decodes its repositories through openReadOnly")
    func olderDatabaseStillDecodesRepositories() async throws {
        let fixture = try databaseBeforeTheMethodColumn()
        defer { fixture.remove() }

        // The fixture is genuinely pre-method rather than a current database that
        // happens to hold a NULL. Without this self-check the test would pass
        // against the newest schema and prove nothing at all.
        let check = try DatabaseQueue(path: fixture.url.path)
        let columns = try await check.read { db in
            Set(try Row.fetchAll(db, sql: "PRAGMA table_info(repo)")
                .compactMap { $0["name"] as String? })
        }
        #expect(!columns.contains("methodID"), "the fixture is not actually a pre-method database")
        try check.close()

        let older = try BoardStore.openReadOnly(at: fixture.url)
        let loaded = try #require(
            try await older.repos().first,
            "openReadOnly answered no repository at all on a pre-method database")
        #expect(loaded.displayName == "Koine", "the pre-method row is still there, unchanged")
        #expect(loaded.methodID == nil, "the added column reads as absent, not as a decode failure")

        guard case .unset(let pack) = loaded.method else {
            Issue.record("a repository that never chose resolved to \(loaded.method)")
            return
        }
        #expect(pack.id == MethodCatalog.defaultPackID)
    }

    /// ⛔ The test the migration's own fifteen-line comment needs in order to be
    /// worth anything.
    @Test("Running v15 over an existing row leaves methodID NULL — there is no DEFAULT")
    func v15DoesNotBackfillExistingRows() throws {
        // Without this, `ADD COLUMN methodID TEXT DEFAULT 'ai-migration-kit'`
        // passes every other test in this plan: SQLite backfills every existing
        // row, every pre-packs repository silently becomes `.chosen` instead of
        // `.unset`, and the whole suite stays green. `olderDatabaseStillDecodes…`
        // cannot see it because it stops *before* v15 runs.
        let fixture = try databaseBeforeTheMethodColumn()
        defer { fixture.remove() }

        let queue = try DatabaseQueue(path: fixture.url.path)
        try Migrations.migrator.migrate(queue)   // the full set, v15 included
        let loaded = try queue.read { db in try Repo.fetchOne(db, key: fixture.repoID) }
        let repo = try #require(loaded)
        #expect(repo.methodID == nil, "v15 backfilled an existing row — it must carry no DEFAULT")
        guard case .unset = repo.method else {
            Issue.record("an existing row stopped reading as never-chosen: \(repo.method)")
            return
        }
        try queue.close()
    }

    /// The other half: the column is real, and the id survives the round trip
    /// with no `Repo.Columns` entry and no `CodingKeys` — which is the mapping
    /// this task deliberately does not write.
    @Test("A chosen method round-trips through the new column")
    func chosenMethodRoundTrips() async throws {
        let store = try BoardStore.inMemory()
        var repository = Repo(
            path: "/tmp/repo-\(UUID().uuidString)",
            nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot"
        )
        repository.methodID = "gsd"
        try await store.saveRepo(repository)

        let loaded = try #require(try await store.repo(id: repository.id))
        #expect(loaded.methodID == "gsd", "the column carries the id verbatim")
    }
}
