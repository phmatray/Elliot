import ElliotEngine
import ElliotModel
import ElliotProcess
import Foundation
import TestSupport
import Testing

@testable import ElliotAppKit

/// The per-repository sweep: what it records, and the guard that stops a second
/// one running over the first (#302).
///
/// It drives a **real** `PreflightService` against a real clone and
/// `Scripts/fake-gh.sh`, for the reason `GHClient`'s own suites do: the seam is
/// `ToolConfig`, so the real subprocesses, the real `git` and the real recording
/// path all stay under test and nothing about production changes to allow it.
@Suite("Preflight sweep")
@MainActor
struct PreflightSweepTests {

    private enum Paths {
        static let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ElliotAppKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ElliotKit
            .deletingLastPathComponent()   // repo root

        static let fakeGH = repoRoot.appendingPathComponent("Scripts/fake-gh.sh").path
    }

    private func service(argv: String) -> PreflightService {
        PreflightService(
            environment: LoginShellEnvironment(variables: [:], capturedVia: "test"),
            config: ToolConfig(
                claudePath: "/usr/bin/false",
                ghPath: Paths.fakeGH,
                gitPath: "/usr/bin/git",
                environment: ["FAKE_GH_ARGV_OUT": argv, "PATH": "/usr/bin:/bin"]
            )
        )
    }

    private func argvFile() -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweep-argv-\(UUID().uuidString)").path
        FileManager.default.createFile(atPath: path, contents: nil)
        return path
    }

    /// How many times `gh` was actually spawned: `repoChecks` asks it exactly
    /// once per repository (`gh repo view`), and the fake logs its argv before
    /// it dispatches, so the count survives the 64 it exits with.
    private func ghCalls(in argv: String) -> Int {
        let text = (try? String(contentsOfFile: argv, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").count { $0 == "view" }
    }

    @Test("A sweep records a reading per repository, with the moment it was taken")
    func aSweepRecordsReadings() async throws {
        _ = TestHome.root
        let pair = try await makeClonePair()
        defer { try? FileManager.default.removeItem(atPath: pair.root) }

        let repo = Repo(path: pair.clone, nameWithOwner: "o/clone", displayName: "clone")
        let model = AppModel()
        model.testOnlySeed(repos: [repo], cards: [])
        #expect(model.repoReadings[repo.id] == nil, "nothing has been read before the sweep")

        let before = Date.now
        await model.refreshRepoChecks(using: service(argv: argvFile()))

        let reading = try #require(model.repoReadings[repo.id])
        #expect(reading.checkedAt >= before)
        // A real checkout, so the first two checks pass and the reading is a
        // measurement rather than a stand-in.
        #expect(reading.results.first { $0.id == "repo.exists" }?.status == .pass)
        #expect(reading.results.first { $0.id == "repo.isMainCheckout" }?.status == .pass)
        // And the first *failure* is what a card would name: no repo profile in
        // a bare clone, which comes before the GitHub identity in the service's
        // own order.
        #expect(reading.blocking?.id == "repo.profile")
        #expect(reading.verdict == .failing)
    }

    /// ⛔ The re-entrancy guard, measured by counting the subprocesses.
    ///
    /// The launch sweep and *Check again* reach the same method, and both are
    /// live at once on a slow start. Without the guard the second pass runs
    /// every `gh` and `git` call again — on the screen most likely to meet
    /// GitHub's rate limit — and lands a second reading per repository.
    ///
    /// The interleaving is deterministic rather than lucky: `refreshRepoChecks`
    /// sets the flag before its first suspension point, so whichever call the
    /// main actor runs first is the one that sweeps.
    @Test("A second sweep started over the first does nothing at all")
    func oneSweepAtATime() async throws {
        _ = TestHome.root
        let pair = try await makeClonePair()
        defer { try? FileManager.default.removeItem(atPath: pair.root) }

        let repos = (0..<3).map { index in
            Repo(path: pair.clone, nameWithOwner: "o/clone\(index)", displayName: "clone\(index)")
        }
        let model = AppModel()
        model.testOnlySeed(repos: repos, cards: [])

        let argv = argvFile()
        let sweeper = service(argv: argv)
        async let first: Void = model.refreshRepoChecks(using: sweeper)
        async let second: Void = model.refreshRepoChecks(using: sweeper)
        _ = await (first, second)

        #expect(ghCalls(in: argv) == 3, "the second call swept again instead of standing down")
        #expect(model.repoReadings.count == 3)
        #expect(!model.isCheckingRepos, "the flag outlived the sweep that set it")
    }

    /// The flag is what the button is disabled by, so it has to be false again
    /// afterwards even when the sweep had nothing to do.
    @Test("The flag is lowered again when there is not a single repository")
    func theFlagIsLoweredOnAnEmptyBoard() async throws {
        _ = TestHome.root
        let model = AppModel()
        model.testOnlySeed(repos: [], cards: [])

        await model.refreshRepoChecks(using: service(argv: argvFile()))
        #expect(!model.isCheckingRepos)
        #expect(model.repoReadings.isEmpty)
    }

    /// Ten repositories through a window of eight is the case where the "start
    /// eight, then one more each time one finishes" loop can drop or repeat an
    /// index. Every repository must be read exactly once.
    @Test("Every repository is read exactly once, past the width of the window")
    func everyRepositoryIsReadOnce() async throws {
        _ = TestHome.root
        let pair = try await makeClonePair()
        defer { try? FileManager.default.removeItem(atPath: pair.root) }

        let repos = (0..<10).map { index in
            Repo(path: pair.clone, nameWithOwner: "o/clone\(index)", displayName: "clone\(index)")
        }
        let model = AppModel()
        model.testOnlySeed(repos: repos, cards: [])

        let argv = argvFile()
        await model.refreshRepoChecks(using: service(argv: argv))

        #expect(model.repoReadings.count == 10)
        #expect(ghCalls(in: argv) == 10)
        for repo in repos {
            #expect(model.repoReadings[repo.id] != nil, "\(repo.displayName) was never read")
        }
    }
}
