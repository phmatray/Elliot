import ElliotModel
import Foundation
import GRDB
import TestSupport
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

    /// `repos()` is the one-shot read and still decodes all-or-nothing. Left
    /// that way deliberately: its callers ask for the list to act on it, and a
    /// silently short list there would be the defect this issue is about. The
    /// **observation** is the path the board draws from, and that one is now
    /// per-row — see `observeRepos` below.
    @Test("The one-shot read still refuses a set it cannot fully decode")
    func oneShotReadStillThrows() async throws {
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

    // MARK: - The observation, which is what the board draws from

    /// Criterion 4, and the point of the whole task: one bad row costs one
    /// repository, not the list.
    @Test("One unreadable row still yields the readable ones, and is counted")
    func oneBadRowCostsOneRepository() async throws {
        let store = try await storeOnDisk(repoIDs: ["sandbox", UUID().uuidString])

        let scan = try #require(try await firstScan(from: store))

        #expect(scan.repos.count == 1, "the good row was lost with the bad one")
        #expect(scan.unreadable == 1)
        // And it is the *right* row that survived, not merely a row.
        #expect(scan.repos.first?.displayName == "Repo 1")
    }

    /// The skip has to reach a surface. A count nobody renders is the original
    /// defect with a smaller radius — the board would quietly show fewer
    /// repositories than exist and call it fine.
    @Test("A skipped row produces a sentence for the board to show")
    func aSkippedRowIsSaidOutLoud() async throws {
        let store = try await storeOnDisk(repoIDs: ["sandbox", UUID().uuidString])
        let scan = try #require(try await firstScan(from: store))

        let note = try #require(BoardPhase.skippedNote(scan.unreadable))
        #expect(note.contains("1 repository"))
        // And a healthy read says nothing at all.
        #expect(BoardPhase.skippedNote(0) == nil)
    }

    @Test("Every row readable yields every repository and no complaint")
    func aCleanStoreScansClean() async throws {
        let store = try await storeOnDisk(repoIDs: [UUID().uuidString, UUID().uuidString])
        let scan = try #require(try await firstScan(from: store))

        #expect(scan.repos.count == 2)
        #expect(scan.unreadable == 0)
        #expect(BoardPhase.skippedNote(scan.unreadable) == nil)
    }

    /// Every row bad is **not** an empty store. Those are different answers and
    /// #42 exists because they were once the same screen.
    @Test("A store whose every row is unreadable says so, and is not called empty")
    func everyRowUnreadableIsNotEmpty() async throws {
        let store = try await storeOnDisk(repoIDs: ["sandbox", "also-not-a-uuid"])
        let scan = try #require(try await firstScan(from: store))

        #expect(scan.repos.isEmpty)
        #expect(scan.unreadable == 2)

        let phase = BoardPhase.of(
            hasLoadedRepos: true, isReady: true, repoCount: scan.repos.count,
            failure: nil, unreadableCount: scan.unreadable)
        #expect(phase != .empty)
        #expect(phase.isFailure)
    }

    /// The first value the observation publishes, bounded so a wedged
    /// observation fails the suite instead of hanging it.
    /// Bounded, per this package's testing discipline: a wedged observation
    /// fails the suite in seconds instead of hanging `swift test` and the
    /// SwiftPM build lock with it.
    private func firstScan(from store: BoardStore) async throws -> RepoScan? {
        try await withTimeout(.seconds(5)) {
            for try await scan in store.observeRepos() { return scan }
            return nil
        }
    }
}
