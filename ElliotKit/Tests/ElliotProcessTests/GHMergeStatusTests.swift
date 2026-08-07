import ElliotModel
import Foundation
import Testing

@testable import ElliotProcess

/// Drives the **real** subprocess and the **real** decoder through
/// `Scripts/fake-gh.sh`, the same seam `GitHubImportFromFakeGHTests` uses. The
/// three fixtures are verbatim `gh pr view` captures taken with the exact
/// `--json` set `GHClient.mergeStatus` sends, so a drift between client and
/// capture shows up here as a decode failure rather than as a silent `nil`.
///
/// They are the three cases #174's spec names, and each was observed on this
/// repository on 2026-08-07:
///
/// | fixture | pull request | what it carries |
/// |---|---|---|
/// | `pr-view-unstable` | #172 | `UNSTABLE`, one check `IN_PROGRESS` |
/// | `pr-view-conflict` | #149 | `DIRTY` / `CONFLICTING`, no checks at all |
/// | `pr-view-merged`   | #163 | merged, `UNKNOWN` / `UNKNOWN`, empty rollup |
@Suite("gh merge status")
struct GHMergeStatusTests {

    private static let fakeGH = TestPaths.repoRoot
        .appendingPathComponent("Scripts/fake-gh.sh").path

    private static func ghFixture(_ name: String) -> String {
        TestPaths.repoRoot.appendingPathComponent("Fixtures/gh/\(name)").path
    }

    private func client(_ fixture: String, argvOut: String? = nil) -> GHClient {
        var env = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "FAKE_GH_PR_VIEW": Self.ghFixture(fixture),
        ]
        if let argvOut { env["FAKE_GH_ARGV_OUT"] = argvOut }
        return GHClient(config: ToolConfig(
            claudePath: "", ghPath: Self.fakeGH, gitPath: "", environment: env))
    }

    private func temporaryFile() -> String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fake-gh-argv-\(UUID().uuidString)").path
    }

    // MARK: - The four fields this task adds

    @Test("A conflicted pull request decodes as DIRTY and CONFLICTING")
    func conflictDecodes() async throws {
        let status = try await client("pr-view-conflict.json")
            .mergeStatus(repo: "phmatray/Elliot", number: 149)
        #expect(status.mergeStateStatus == "DIRTY")
        #expect(status.mergeable == "CONFLICTING")
        #expect(status.reviewDecision == "")
        #expect(status.headRefOid == "898b1aee67d8d94a9c15869046e43d45dab5e1b8")
        #expect(status.statusCheckRollup?.isEmpty == true)
    }

    @Test("An in-progress check decodes with its status, which is what tells running from passed")
    func inProgressCheckDecodes() async throws {
        let status = try await client("pr-view-unstable.json")
            .mergeStatus(repo: "phmatray/Elliot", number: 172)
        #expect(status.mergeStateStatus == "UNSTABLE")
        #expect(status.mergeable == "MERGEABLE")

        let check = try #require(status.statusCheckRollup?.first)
        #expect(check.label == "floor")
        #expect(check.status == "IN_PROGRESS")
        // Captured from the wire: `gh` renders an unfinished check's conclusion
        // as an empty string, NOT as null. Reading absence as `nil` alone would
        // have counted this check as finished.
        #expect(check.conclusion == "")
        #expect(check.isPending)
        #expect(!check.hasFailed)
    }

    @Test("A merged pull request carries its merge commit and an empty rollup")
    func mergedDecodes() async throws {
        let status = try await client("pr-view-merged.json")
            .mergeStatus(repo: "phmatray/Elliot", number: 163)
        #expect(status.isMerged)
        #expect(status.mergeCommit?.oid == "9de425e0b6516651848033100ced98d01ce7f1ed")
        // The head ref is gone once a pull request lands, so "no checks" says
        // nothing here. #174 only ever reads In Review, which is why this is
        // recorded rather than guarded against.
        #expect(status.statusCheckRollup?.isEmpty == true)
        #expect(status.mergeStateStatus == "UNKNOWN")
    }

    // MARK: - The request and the capture must name the same fields

    @Test("mergeStatus asks gh for every field the fixtures carry")
    func requestNamesTheNewFields() async throws {
        let argv = temporaryFile()
        _ = try await client("pr-view-conflict.json", argvOut: argv)
            .mergeStatus(repo: "phmatray/Elliot", number: 149)

        let asked = try String(contentsOfFile: argv, encoding: .utf8)
        // A field the client stops asking for arrives as nil, which decodes
        // perfectly — nothing else would notice the two drifting apart.
        for field in ["mergeable", "mergeStateStatus", "reviewDecision", "headRefOid",
                      "statusCheckRollup"] {
            #expect(asked.contains(field), "mergeStatus no longer asks for \(field)")
        }
    }

    @Test("pr list asks for headRefOid — the scalar that makes the skip rule possible")
    func listAsksForHeadOid() {
        #expect(GHClient.pullRequestListFields.contains("headRefOid"))
    }

    // MARK: - The facets, end to end from a real capture

    @Test("The conflict fixture resolves to a conflict sign")
    func conflictResolvesToASign() async throws {
        let status = try await client("pr-view-conflict.json")
            .mergeStatus(repo: "phmatray/Elliot", number: 149)
        let resolved = status.prStatus(repoID: UUID(), prNumber: 149, checkedAt: .now)
            .resolved(now: .now, currentHeadOid: status.headRefOid)
        #expect(resolved.merge == .conflict)
        #expect(resolved.sign == .conflict)
        // Zero checks *and* a conflict: the conflict is the one worth saying,
        // because a conflicted pull request fires no workflow to begin with.
        #expect(resolved.ci == .noChecks)
    }

    @Test("The unstable fixture resolves to a running check")
    func unstableResolvesToRunning() async throws {
        let status = try await client("pr-view-unstable.json")
            .mergeStatus(repo: "phmatray/Elliot", number: 172)
        let resolved = status.prStatus(repoID: UUID(), prNumber: 172, checkedAt: .now)
            .resolved(now: .now, currentHeadOid: status.headRefOid)
        #expect(resolved.ci == .running)
        #expect(resolved.merge == .unstable)
        #expect(resolved.sign == .checksRunning)
    }

    // MARK: - The fake still fails loudly on anything it does not know

    @Test("An unexpected subcommand still exits 64 rather than returning nothing")
    func unknownSubcommandStillFailsLoudly() async throws {
        let result = try await ProcessRunner.run(
            executable: Self.fakeGH,
            arguments: ["repo", "delete", "--yes"],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            timeout: .seconds(20))
        #expect(result.exitCode == 64)
    }

    @Test("A pr view with no fixture configured fails rather than inventing an object")
    func missingFixtureFailsLoudly() async throws {
        // `emit` answers `[]` for a missing *list* fixture because that is what
        // `gh` returns for an empty repository. There is no such thing as an
        // empty object here, so this path must refuse instead.
        let result = try await ProcessRunner.run(
            executable: Self.fakeGH,
            arguments: ["pr", "view", "1", "--repo", "phmatray/Elliot", "--json", "state"],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            timeout: .seconds(20))
        #expect(!result.succeeded)
    }
}
