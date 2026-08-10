import ElliotIPC
import Foundation
import GRDB
import Testing

@testable import ElliotMCPKit
// `@testable` for `Migrations.migrator`, which is internal: reproducing a helper
// that meets an older file honestly needs a database migrated *part* of the way.
@testable import ElliotStore

/// Its own file because of `import GRDB`.
///
/// GRDB exports a `Column` type, and `Column` means the board's five columns
/// everywhere in Elliot — importing it into a file that also names the board's
/// columns makes every one of them ambiguous. `ElliotStore` keeps the two apart
/// with a `SQLColumn` alias; a test file can simply not import both.
@Suite("A database older than the helper")
struct OlderDatabaseTests {

    /// The window `openReadOnly` exists to keep working, and which #174 nearly
    /// closed.
    ///
    /// `openReadOnly` deliberately accepts a database **older** than the helper
    /// — `applied.isSubset(of: known)` — so the board is not blanked between
    /// upgrading the bundle and the next launch of the app. That tolerance was
    /// written for added *columns*, which read as absent. `v8_prStatus` adds a
    /// **table**, and querying one that does not exist throws rather than
    /// answering nil. The error escaped `dto(for:)` into `AppBridge.read`'s
    /// catch, so every offline `board_get_card` answered
    /// `app_unavailable: "no such table: prStatus"` in exactly the window
    /// `openReadOnly` is there to serve.
    ///
    /// Worth keeping as a test rather than a comment: the next feature to add a
    /// table will reach for the same `try await store.…` and this is what will
    /// tell it.
    @Test("It still answers a card, it does not refuse the whole read")
    func olderDatabaseStillAnswers() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elliot-v7-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        // Only as far as the release before this feature, then seed through raw
        // SQL — the record types know about a table this file must not have.
        let queue = try DatabaseQueue(path: url.path)
        try Migrations.migrator.migrate(queue, upTo: "v7_cardAngle")

        let repoID = UUID().uuidString.uppercased()
        let cardID = UUID()
        try await queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO repo (id, path, nameWithOwner, defaultBranch, displayName,
                        permissionMode, extraAllowedTools, isEnabled)
                    VALUES (?, '/tmp/older', 'phmatray/Elliot', 'main', 'Elliot',
                        'bypassPermissions', '[]', 1)
                    """,
                arguments: [repoID])
            try db.execute(
                sql: """
                    INSERT INTO card (id, repoID, title, body, "column", orderIndex,
                        prNumber, columnEnteredAt, createdAt, updatedAt)
                    VALUES (?, ?, 'Merge me', '', 'inReview', 0, 52,
                        '2026-08-07 10:00:00.000', '2026-08-07 10:00:00.000',
                        '2026-08-07 10:00:00.000')
                    """,
                arguments: [cardID.uuidString.uppercased(), repoID])
        }
        try queue.close()

        // The table this feature added is genuinely absent.
        let check = try DatabaseQueue(path: url.path)
        let exists = try await check.read { db in try db.tableExists("prStatus") }
        #expect(!exists, "the fixture is not actually a pre-v8 database")
        try check.close()

        let older = try BoardStore.openReadOnly(at: url)
        let responder = OfflineResponder(store: older)

        let response = await responder.respond(to: .getCard(id: cardID))
        guard case .ok(let payload) = response, case .card(let dto) = payload else {
            Issue.record("the helper refused a card on a pre-v8 database: \(response)")
            return
        }
        // No reading is the honest answer on a database that cannot hold one.
        #expect(dto.prStatus == nil)
        #expect(dto.prNumber == 52)
    }

    /// The same tolerance, for a **repository** rather than a card (#199).
    ///
    /// The test above migrates to v7 and reads a `card`; `Repo` has its own
    /// decoder and its own list of columns, so it is a separate claim. `Repo`
    /// gained `labelPolicy` in v14, and a helper carrying that knowledge meets a
    /// v13 file every time a bundle is upgraded before the app next launches.
    /// Declared non-optional, the synthesised decoder emits `decode(_:forKey:)`
    /// rather than `decodeIfPresent` and throws `keyNotFound` on **every**
    /// repository — the `@DefaultsToEmpty` defect CLAUDE.md records, one type
    /// over, and the reason this column is an `Optional` rather than a
    /// defaulted array.
    @Test("It still answers a repository whose policy column does not exist yet")
    func olderDatabaseStillAnswersARepository() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elliot-v13-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let queue = try DatabaseQueue(path: url.path)
        try Migrations.migrator.migrate(queue, upTo: "v13_runResumedFrom")
        try await queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO repo (id, path, nameWithOwner, defaultBranch, displayName,
                        permissionMode, extraAllowedTools, isEnabled)
                    VALUES (?, '/tmp/older', 'phmatray/Elliot', 'main', 'Elliot',
                        'bypassPermissions', '[]', 1)
                    """,
                arguments: [UUID().uuidString.uppercased()])
        }
        try queue.close()

        let check = try DatabaseQueue(path: url.path)
        let exists = try await check.read { db in
            try db.columns(in: "repo").contains { $0.name == "labelPolicy" }
        }
        #expect(!exists, "the fixture is not actually a pre-v14 database")
        try check.close()

        let older = try BoardStore.openReadOnly(at: url)
        let repos = try await older.repos()
        #expect(repos.count == 1, "the helper refused every repository on a pre-v14 database")
        // Absent reads as "nobody has chosen", which is the truth: nothing could
        // have written a value into a column that does not exist.
        #expect(repos.first?.labelPolicy == nil)
    }
}
