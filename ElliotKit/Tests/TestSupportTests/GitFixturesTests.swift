import Foundation
import Testing
import TestSupport

/// The probe the end-to-end sentinels gate themselves on, and the throw their
/// set-up leans on. Both are one line of `TestSupport` that four suites in
/// another target depend on, so they are pinned here rather than nowhere.
@Suite("Git fixtures")
struct GitFixturesTests {

    @Test("The probe answers for the path the fixtures actually spawn")
    func theProbeAndThePathAgree() {
        // The two halves are asserted against each other on purpose: a probe
        // that measured a *different* path would report a `git` that the
        // fixtures cannot run, which is the failure a `.enabled(if:)` trait
        // would then hide behind a plausible skip.
        #expect(gitFixturePath == "/usr/bin/git")
        #expect(
            gitFixtureIsAvailable
                == FileManager.default.isExecutableFile(atPath: gitFixturePath))
    }

    @Test(
        "A refused git throws rather than being swallowed",
        .enabled(if: gitFixtureIsAvailable))
    func aRefusedGitThrows() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-fixture-refusal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Not a repository and not inside one, so `git status` exits non-zero.
        // This is the case `_ = try? await …` turned into a silent success, and
        // the reason the end-to-end suites' `git init` now goes through here.
        await #expect(throws: GitFixtureFailed.self) {
            try await git(["status"], in: root.path)
        }
    }

    @Test("A git that succeeds returns rather than throwing", .enabled(if: gitFixtureIsAvailable))
    func anAcceptedGitReturns() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-fixture-init-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The other direction, so the test above cannot pass because `git`
        // throws for everything.
        try await git(["init", "-q"], in: root.path)
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(".git").path))
    }
}
