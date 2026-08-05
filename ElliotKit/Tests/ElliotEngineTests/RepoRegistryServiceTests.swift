import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine

/// `/usr/bin/true` rather than a real `gh`: the suite must not reach the network
/// or need a token. `repoInfo` then yields nothing and the service falls back to
/// what the path itself says, which is the branch these tests exercise.
private func testConfig() -> ToolConfig {
    ToolConfig(
        claudePath: "/usr/bin/true", ghPath: "/usr/bin/true", gitPath: "/usr/bin/true",
        environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    )
}

private func makeTree() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("tree-\(UUID().uuidString)").path
}

@Suite("Repo registry service", .serialized)
struct RepoRegistryServiceTests {

    @Test("Registering writes the repo with its visibility; forgetting removes it and leaves the disk alone")
    func registerAndForget() async throws {
        let root = makeTree(), path = root + "/phmatray/private/Koine"
        try FileManager.default.createDirectory(atPath: path + "/.git", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let layout = RepoTreeLayout(root: root, owners: ["phmatray"])
        let store = try BoardStore.inMemory()
        let service = RepoRegistryService(store: store, config: testConfig())

        #expect(await service.apply(.register(path: path), layout: layout).succeeded)
        let saved = try await store.repo(path: path)
        #expect(saved?.visibility == .private)
        #expect(saved?.displayName == "Koine")

        #expect(await service.apply(.forget(repoID: saved!.id), layout: layout).succeeded)
        #expect(try await store.repo(path: path) == nil)
        #expect(
            FileManager.default.fileExists(atPath: path + "/.git"),
            "forget never touches the disk")
    }

    @Test("Moving relocates the clone and repoints the registration in the same step")
    func moveRepointsTheRegistration() async throws {
        let root = makeTree()
        let from = root + "/phmatray/public/Koine", to = root + "/phmatray/private/Koine"
        try FileManager.default.createDirectory(atPath: from + "/.git", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let layout = RepoTreeLayout(root: root, owners: ["phmatray"])
        let store = try BoardStore.inMemory()
        try await store.saveRepo(
            Repo(
                path: from, nameWithOwner: "phmatray/Koine",
                displayName: "Koine", visibility: .public))
        let service = RepoRegistryService(store: store, config: testConfig())

        #expect(await service.apply(.move(from: from, to: to), layout: layout).succeeded)
        #expect(FileManager.default.fileExists(atPath: to + "/.git"))
        #expect(try await store.repo(path: from) == nil, "the store never points at a moved-away path")
        #expect(try await store.repo(path: to)?.visibility == .private)
    }

    @Test("A failing fix reports its reason and changes nothing")
    func failureIsPerRow() async throws {
        let store = try BoardStore.inMemory()
        let service = RepoRegistryService(store: store, config: testConfig())
        let outcome = await service.apply(
            .register(path: "/nope/\(UUID().uuidString)"), layout: .portfolio)
        #expect(!outcome.succeeded)
        #expect(!outcome.detail.isEmpty)
        #expect(try await store.repos().isEmpty)
    }
}
