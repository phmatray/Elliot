import Foundation
import Testing
import TestSupport

/// The probe the end-to-end sentinels gate themselves on, and the throw their
/// set-up leans on. Both are one line of `TestSupport` that four suites in
/// another target depend on, so they are pinned here rather than nowhere.
@Suite("Git fixtures")
struct GitFixturesTests {

    /// A directory that is certainly not a git repository, and certainly not
    /// inside one.
    ///
    /// ⚠️ `temporaryDirectory` alone is not enough: a machine with `TMPDIR`
    /// pointed under a checkout — a common habit, and what some sandboxes do —
    /// makes `git` walk up, find a `.git`, and succeed. Every command below is
    /// therefore chosen to fail (or succeed) for a reason that does not depend
    /// on what encloses the directory.
    private func scratch(_ name: String) throws -> (URL, () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-fixture-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, { try? FileManager.default.removeItem(at: root) })
    }

    @Test("The probe answers for the path the fixtures actually spawn")
    func theProbeNamesTheSpawnedBinary() {
        // Pinned against the literal, not against a re-evaluation of the probe's
        // own definition: `gitFixtureIsAvailable == isExecutableFile(atPath:
        // gitFixturePath)` would restate the definition and could only fail if
        // the filesystem changed mid-run — a green assertion asserting nothing,
        // which is the defect this whole change exists to remove. What is worth
        // holding is that the constant still names the binary the fixtures and
        // the suites were written against.
        #expect(gitFixturePath == "/usr/bin/git")
    }

    @Test(
        "A probe that says yes means a git that really runs",
        .enabled(if: gitFixtureIsAvailable))
    func anAvailableGitActuallyRuns() async throws {
        let (root, remove) = try scratch("version")
        defer { remove() }
        // The falsifiable half, and the one the tautology above could not reach:
        // `gitFixtureIsAvailable` measures presence, so this is what connects it
        // to runnability. `--version` needs no repository, so it answers the
        // same wherever `TMPDIR` points.
        try await git(["--version"], in: root.path)
    }

    @Test("A refused git throws rather than being swallowed", .enabled(if: gitFixtureIsAvailable))
    func aRefusedGitThrows() async throws {
        let (root, remove) = try scratch("refusal")
        defer { remove() }

        // An unknown subcommand, not `status`: `git` rejects it before looking
        // for a repository, so this fails identically inside a checkout and
        // outside one. This is the case `_ = try? await …` turned into a silent
        // success, and the reason the end-to-end suites' `git init` goes
        // through here now.
        await #expect(throws: GitFixtureFailed.self) {
            try await git(["definitely-not-a-subcommand"], in: root.path)
        }
    }

    @Test("A git that succeeds returns rather than throwing", .enabled(if: gitFixtureIsAvailable))
    func anAcceptedGitReturns() async throws {
        let (root, remove) = try scratch("init")
        defer { remove() }

        // The other direction, so the test above cannot pass merely because
        // `git()` throws for everything.
        try await git(["init", "-q"], in: root.path)
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(".git").path))
    }

    // ⛔ The `timeout:` bound `git()` gained is deliberately **not** asserted
    // here, and the reason is this suite's own discipline rather than an
    // oversight. Driving it needs a `git` that hangs, which no argument produces
    // without a network or a TTY, and the near alternatives are both worse than
    // no test: a tiny deadline races the spawn — the watchdog can fire before
    // `run()` has started, find nothing running, and let the command succeed —
    // and any fixed interval is a wall-clock assertion, which fails under load
    // while the code behaved perfectly. A flaky witness to a safety property is
    // worth less than a named gap.
}
