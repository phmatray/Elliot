import Foundation
import TestSupport
import Testing

@testable import ElliotProcess

/// A real `/usr/bin/git` — these four verbs are the ones that cannot be proven
/// against `/usr/bin/true`, because what is asserted is what git *answered*.
/// `gh` stays a stub: nothing here reaches the network or needs a token.
private func testConfig() -> ToolConfig {
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

@Suite("Git sync verbs", .serialized)
struct GitClientSyncTests {

    @Test("aheadBehind reads a local ref: it only sees the drift after a fetch")
    func fetchIsRequired() async throws {
        let (origin, clone, root) = try await makeClonePair()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let client = GitClient(config: testConfig())

        try await git(["commit", "--allow-empty", "-m", "b"], in: origin)
        #expect(await client.aheadBehind(cwd: clone)?.behind == 0, "@{u} is stale until a fetch")

        try await client.fetch(cwd: clone)
        #expect(await client.aheadBehind(cwd: clone)?.behind == 1)
    }

    @Test("A behind clone fast-forwards to zero")
    func fastForward() async throws {
        let (origin, clone, root) = try await makeClonePair()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let client = GitClient(config: testConfig())

        try await git(["commit", "--allow-empty", "-m", "b"], in: origin)
        try await client.pullFastForward(cwd: clone)
        try await client.fetch(cwd: clone)
        let counts = await client.aheadBehind(cwd: clone)
        #expect(counts?.ahead == 0)
        #expect(counts?.behind == 0)
    }

    @Test("A diverged clone is refused rather than merged, and is left untouched")
    func refusesToMerge() async throws {
        let (origin, clone, root) = try await makeClonePair()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let client = GitClient(config: testConfig())

        try await git(["commit", "--allow-empty", "-m", "b"], in: origin)
        try await git(["commit", "--allow-empty", "-m", "c"], in: clone)
        try await client.fetch(cwd: clone)
        let before = await client.aheadBehind(cwd: clone)
        #expect(before?.ahead == 1)
        #expect(before?.behind == 1)

        await #expect(throws: (any Error).self) { try await client.pullFastForward(cwd: clone) }

        let after = await client.aheadBehind(cwd: clone)
        #expect(after?.ahead == 1, "the tree is untouched")
        #expect(after?.behind == 1, "the tree is untouched")
    }

    @Test("A detached HEAD is reported")
    func detached() async throws {
        let (_, clone, root) = try await makeClonePair()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let client = GitClient(config: testConfig())

        #expect(await client.isDetached(cwd: clone) == false)
        try await git(["checkout", "--detach"], in: clone)
        #expect(await client.isDetached(cwd: clone))
    }

    @Test("A clone with no upstream has no counts at all, rather than zeroes")
    func noUpstream() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("solo-\(UUID().uuidString)").path
        let solo = root + "/solo"
        try FileManager.default.createDirectory(atPath: solo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try await git(["init", "--initial-branch=main"], in: solo)
        try await git(["commit", "--allow-empty", "-m", "a"], in: solo)

        // nil, not (0, 0): a repository with no remote is a different verdict
        // from one that is up to date, and the classifier has to tell them apart.
        #expect(await GitClient(config: testConfig()).aheadBehind(cwd: solo) == nil)
    }
}
