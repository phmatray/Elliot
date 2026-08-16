import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine

/// Registering a checkout has one implementation.
///
/// It had two. `AppModel.addRepo` wrote no `visibility` and never verified a
/// `.git`; `RepoRegistryService.register` refused a non-repository and derived
/// `visibility` from the layout slot. `visibility` is what `expectedPath` uses
/// to decide where a clone belongs, so the *same directory* could later be
/// reported misplaced — or silently exempted — purely according to which button
/// had registered it.
@Suite("Registration is one act", .serialized)
struct RegistrationIsOneActTests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func config() -> ToolConfig {
        ToolConfig(
            ghPath: repoRoot.appendingPathComponent("Scripts/fake-gh.sh").path,
            gitPath: "/usr/bin/true",
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        )
    }

    private static func tree() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("reg-\(UUID().uuidString)").path
    }

    private static func clone(_ path: String) throws {
        try FileManager.default.createDirectory(
            atPath: path + "/.git", withIntermediateDirectories: true)
    }

    /// ⛔ The defect the idempotence exists for. `Repo.save` keys on `id`, so a
    /// second registration of a directory that already had one inserted a
    /// *second* row with a fresh `UUID` — an orphan the cards do not point at,
    /// and nothing on the page tells the two apart.
    @Test("Registering the same directory twice leaves one row, with its id intact")
    func registrationIsIdempotentOnPath() async throws {
        let root = Self.tree(), path = root + "/phmatray/private/Koine"
        try Self.clone(path)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let layout = RepoTreeLayout(root: root, owners: ["phmatray"])
        let store = try BoardStore.inMemory()
        let service = RepoRegistryService(store: store, config: Self.config())

        #expect(await service.apply(.register(path: path), layout: layout).succeeded)
        let first = try #require(try await store.repo(path: path))

        #expect(await service.apply(.register(path: path), layout: layout).succeeded)
        let second = try #require(try await store.repo(path: path))

        #expect(second.id == first.id)
        #expect(try await store.repos().filter { $0.path == path }.count == 1)
    }

    /// The second registration is what repairs a row the old path wrote, so it
    /// must not also undo the reader's own settings.
    @Test("Re-registering fills what was derived and keeps what was chosen")
    func reRegisteringRepairsWithoutResetting() async throws {
        let root = Self.tree(), path = root + "/phmatray/private/Koine"
        try Self.clone(path)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let layout = RepoTreeLayout(root: root, owners: ["phmatray"])
        let store = try BoardStore.inMemory()
        // Exactly what `AppModel.addRepo` used to write: no visibility at all.
        var old = Repo(
            path: path, nameWithOwner: "Koine", defaultBranch: "main", displayName: "Koine")
        old.permissionMode = .acceptEdits
        old.isEnabled = false
        try await store.saveRepo(old)

        let service = RepoRegistryService(store: store, config: Self.config())
        #expect(await service.apply(.register(path: path), layout: layout).succeeded)

        let repaired = try #require(try await store.repo(path: path))
        #expect(repaired.id == old.id)
        // Derived: filled in from the layout slot the old path ignored.
        #expect(repaired.visibility == .private)
        // Chosen: re-registering is not a request to reset these.
        #expect(repaired.permissionMode == .acceptEdits)
        #expect(repaired.isEnabled == false)
    }

    /// ⚠️ A repository outside the tree has no slot. Assigning the slot's
    /// visibility unconditionally would erase one already recorded, and
    /// `expectedPath` would then move on the next reconcile.
    @Test("A path with no layout slot keeps the visibility already recorded")
    func aMissingSlotDoesNotEraseVisibility() async throws {
        let root = Self.tree()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString)").path
        try Self.clone(outside)
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: outside)
        }

        let layout = RepoTreeLayout(root: root, owners: ["phmatray"])
        let store = try BoardStore.inMemory()
        var known = Repo(
            path: outside, nameWithOwner: "phmatray/Loose", defaultBranch: "main",
            displayName: "Loose")
        known.visibility = .public
        try await store.saveRepo(known)

        let service = RepoRegistryService(store: store, config: Self.config())
        #expect(await service.apply(.register(path: outside), layout: layout).succeeded)
        #expect(try await store.repo(path: outside)?.visibility == .public)
    }

    /// This is now the only way in, so the refusal has to carry what the reader
    /// would otherwise have learned from the failing check they can no longer
    /// reach by registering first.
    @Test("A directory that is not a checkout is refused, and told what to choose")
    func aNonRepositoryIsRefusedWithARemedy() async throws {
        let root = Self.tree(), path = root + "/phmatray/private/NotAClone"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let store = try BoardStore.inMemory()
        let service = RepoRegistryService(store: store, config: Self.config())
        let outcome = await service.apply(
            .register(path: path), layout: RepoTreeLayout(root: root, owners: ["phmatray"]))

        #expect(outcome.succeeded == false)
        #expect(outcome.detail.contains(".git"))
        #expect(outcome.detail.contains("not the folder above it"))
        #expect(try await store.repo(path: path) == nil)
    }
}
