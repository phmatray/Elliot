import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import TestSupport
import Testing

@testable import ElliotEngine

/// A real `/usr/bin/git`, because what is under test is the *order* in which the
/// classifier believes git's answers. `gh` stays a stub — no network, no token.
private func syncTestConfig() -> ToolConfig {
    ToolConfig(
        claudePath: "/usr/bin/true", ghPath: "/usr/bin/true", gitPath: "/usr/bin/git",
        environment: [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
        ]
    )
}

@Suite("Repo probe", .serialized)
struct RepoRegistryServiceSyncTests {

    @Test("A dirty clone that is also behind reads dirty — the ordering is the safety property")
    func dirtyBeatsBehind() async throws {
        let (origin, clone, root) = try await makeClonePair()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try await git(["commit", "--allow-empty", "-m", "b"], in: origin)
        FileManager.default.createFile(atPath: clone + "/scratch.txt", contents: Data("x".utf8))

        let service = RepoRegistryService(store: try BoardStore.inMemory(), config: syncTestConfig())
        let probed = await service.probe([RepoRow(id: "o/r", path: clone, issue: .ok)])
        #expect(probed[0].issue == .dirty)
        #expect(probed[0].fixes.isEmpty, "a dirty clone is never offered a pull")
    }

    @Test("A clean clone that is strictly behind is offered a pull")
    func behindIsPullable() async throws {
        let (origin, clone, root) = try await makeClonePair()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try await git(["commit", "--allow-empty", "-m", "b"], in: origin)

        let service = RepoRegistryService(store: try BoardStore.inMemory(), config: syncTestConfig())
        let probed = await service.probe([RepoRow(id: "o/r", path: clone, issue: .ok)])
        #expect(probed[0].issue == .behind(by: 1))
        #expect(probed[0].fixes == [.pull(path: clone)])
        #expect(probed[0].fixes[0].label == "Pull")
    }

    @Test("A clone with local commits is left alone, not offered anything")
    func aheadIsNeverSwept() async throws {
        let (_, clone, root) = try await makeClonePair()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try await git(["commit", "--allow-empty", "-m", "mine"], in: clone)

        let service = RepoRegistryService(store: try BoardStore.inMemory(), config: syncTestConfig())
        let probed = await service.probe([RepoRow(id: "o/r", path: clone, issue: .ok)])
        #expect(probed[0].issue == .ahead)
        #expect(probed[0].fixes.isEmpty)
    }

    @Test("A detached HEAD is reported before anything else is asked")
    func detachedWins() async throws {
        let (origin, clone, root) = try await makeClonePair()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try await git(["commit", "--allow-empty", "-m", "b"], in: origin)
        try await git(["checkout", "--detach"], in: clone)

        let service = RepoRegistryService(store: try BoardStore.inMemory(), config: syncTestConfig())
        let probed = await service.probe([RepoRow(id: "o/r", path: clone, issue: .ok)])
        #expect(probed[0].issue == .detached)
        #expect(probed[0].fixes.isEmpty)
    }

    @Test("A linked worktree is out of scope, never swept")
    func linkedWorktreeIsOutOfScope() async throws {
        let (_, clone, root) = try await makeClonePair()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let linked = root + "/linked"
        try await git(["worktree", "add", "-b", "side", linked], in: clone)

        let service = RepoRegistryService(store: try BoardStore.inMemory(), config: syncTestConfig())
        let probed = await service.probe([RepoRow(id: "o/r", path: linked, issue: .ok)])
        #expect(probed[0].issue == .outOfScope(.otherRoot))
        #expect(probed[0].fixes.isEmpty)
    }

    @Test("Probing leaves a row that is not .ok exactly as it was")
    func onlyRefinesOk() async throws {
        let service = RepoRegistryService(store: try BoardStore.inMemory(), config: syncTestConfig())
        let row = RepoRow(
            id: "o/r", issue: .notCloned,
            fixes: [.clone(nameWithOwner: "o/r", into: "/tmp/x")])
        #expect(await service.probe([row]) == [row])
    }

    @Test("Probing keeps the rows in the order it was given, whatever finishes first")
    func orderIsPreserved() async throws {
        // The page renders rows in place; a probe that returned them in
        // completion order would make every refresh jump under the cursor.
        let (_, clone, root) = try await makeClonePair()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let service = RepoRegistryService(store: try BoardStore.inMemory(), config: syncTestConfig())
        let rows = (0..<20).map { index in
            index % 2 == 0
                ? RepoRow(id: "o/clone-\(index)", path: clone, issue: .ok)
                : RepoRow(id: "o/gone-\(index)", issue: .notCloned)
        }
        let probed = await service.probe(rows)
        #expect(probed.map(\.id) == rows.map(\.id))
    }
}
