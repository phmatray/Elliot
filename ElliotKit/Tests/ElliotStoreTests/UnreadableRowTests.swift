import ElliotModel
import Foundation
import GRDB
import Testing

@testable import ElliotStore

/// The mechanism #118 rests on, measured rather than described.
///
/// The bug was found by hand — a scratch store seeded with `id = 'sandbox'`
/// wedged the board, `uuidgen` did not — and until now that A/B lived only in
/// the issue. This is the same experiment as something `swift test` re-runs.
@Suite("Unreadable repository rows")
struct UnreadableRowTests {

    /// A migrated file plus the rows written straight past the encoder, which
    /// is the only way to produce the row this is about — `saveRepo` takes a
    /// `Repo`, so a `UUID` is the only id it can write.
    /// `Repo.id` is a `UUID` and its column is `TEXT`, so SQLite accepts
    /// anything and the decoder is what refuses. Columns are named rather than
    /// positional: the table has grown twice, and a positional insert would
    /// start failing for a reason that has nothing to do with this test.
    private func storeOnDisk(repoIDs: [String]) async throws -> BoardStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elliot-118-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try Migrations.migrator.migrate(queue)
        try await queue.write { db in
            for (index, id) in repoIDs.enumerated() {
                try db.execute(
                    sql: #"""
                        INSERT INTO "repo"
                            ("id","path","nameWithOwner","defaultBranch","displayName",
                             "permissionMode","extraAllowedTools","isEnabled")
                        VALUES (?,?,?,?,?,?,?,1)
                        """#,
                    arguments: [id, "/tmp/r\(index)", "phmatray/r\(index)", "main",
                                "Repo \(index)", "bypassPermissions", "[]"])
            }
        }
        return try BoardStore.open(at: url)
    }

    @Test("A repository id that is not a UUID makes the whole read throw")
    func oneBadRowThrowsTheWholeFetch() async throws {
        let store = try await storeOnDisk(repoIDs: ["sandbox"])

        await #expect(throws: (any Error).self) {
            _ = try await store.repos()
        }
    }

    /// The control, and the half of the A/B that matters most: the failure
    /// above is caused by the id format and nothing else about the row.
    @Test("The same row with a UUID id reads back fine")
    func theSameRowWithAUUIDReadsFine() async throws {
        let store = try await storeOnDisk(repoIDs: [UUID().uuidString])

        let repos = try await store.repos()
        #expect(repos.count == 1)
        #expect(repos[0].displayName == "Repo 0")
    }

    /// ⚠️ Criterion 4's preferable half, and why it is **not** implemented here.
    ///
    /// `fetchAll` decodes every row or throws, so one bad row costs the whole
    /// list — this asserts that, so the claim in the pull request is a
    /// measurement. Skipping bad rows would mean decoding row by row inside
    /// `observeRepos`, and reporting *how many* were skipped would change what
    /// the observation yields, which the plan says to note rather than do.
    ///
    /// Criterion 4 is still met, by its own "or": a store whose rows cannot be
    /// read says plainly that it can show none, instead of degrading to
    /// silence.
    @Test("A readable row is lost to an unreadable one — the cost this documents")
    func aGoodRowIsLostToABadOne() async throws {
        let store = try await storeOnDisk(repoIDs: ["sandbox", UUID().uuidString])

        // Two rows, one of them perfectly good, and the read still fails.
        await #expect(throws: (any Error).self) {
            _ = try await store.repos()
        }
    }
}
