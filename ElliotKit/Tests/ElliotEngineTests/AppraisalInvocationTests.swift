import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import TestSupport
import Testing

@testable import ElliotEngine

/// The argv a run is spawned with, decided in one pure function so it can be
/// asserted without spawning anything.
///
/// Two facts differ for an appraisal — a tighter permission mode, and the one
/// directory outside the checkout it must be allowed to write — and they travel
/// together here rather than as two `if`s inside a spawn routine, where only one
/// of them would be remembered next time.
@Suite("Appraisal invocation")
struct AppraisalInvocationTests {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func repo(_ mode: PermissionMode = .bypassPermissions) -> Repo {
        Repo(
            path: "/tmp/checkout", nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot", permissionMode: mode
        )
    }

    private func run(_ kind: SkillKind, repoID: UUID) -> SkillRun {
        SkillRun(
            cardID: kind == .analyzeRepo ? nil : UUID(),
            repoID: repoID,
            analysisID: kind == .analyzeRepo ? UUID() : nil,
            kind: kind, prompt: "x", cwd: "/tmp/checkout",
            logPath: "/tmp/a", stderrPath: "/tmp/b", createdAt: now
        )
    }

    @Test("A writer is spawned exactly as it was: the repository's mode, one add-dir")
    func writersAreUnchanged() {
        let repo = repo()
        let invocation = RunScheduler.invocation(
            for: run(.implementIssue, repoID: repo.id), repo: repo, perRunUSD: nil)
        #expect(invocation.permissionMode == .bypassPermissions)
        #expect(invocation.extraDirectories.isEmpty)
        #expect(invocation.arguments().filter { $0 == "--add-dir" }.count == 1)
    }

    @Test("An appraisal is spawned tighter than its repository")
    func appraisalIsTightened() {
        let repo = repo()
        let invocation = RunScheduler.invocation(
            for: run(.appraiseCards, repoID: repo.id), repo: repo, perRunUSD: nil)
        // Not `bypassPermissions`: a denied tool is the whole point. Under the
        // default the MCP self-call is granted in silence and the run ends
        // "success" having driven the board.
        #expect(invocation.permissionMode == .acceptEdits)
    }

    @Test("An appraisal may write its artifact directory, and only that")
    func appraisalCarriesItsArtifactDirectory() throws {
        _ = TestHome.root
        let repo = repo()
        let subject = run(.appraiseCards, repoID: repo.id)
        let invocation = RunScheduler.invocation(for: subject, repo: repo, perRunUSD: nil)

        let expected = StoreLocation.appraisalRunDirectory(runID: subject.id).path
        #expect(invocation.extraDirectories == [expected])

        // Two `--add-dir` pairs, each a single argv element — the artifact lives
        // under `ELLIOT_HOME`, whose real shape carries spaces.
        //
        // Through `argumentValues`, not `args[index + 1]`: a trailing `--add-dir`
        // traps, and a trapped test binary prints no summary line at all, so the
        // one shape this assertion is least equipped to survive would have been
        // reported to CI as a bare exit code.
        #expect(argumentValues(after: "--add-dir", in: invocation.arguments()) == [
            subject.cwd, expected,
        ])
    }

    @Test("An analysis is not tightened by this change")
    func analysesAreUntouched() {
        // Deliberate, and out of scope: an analysis writes its artifact today
        // because it runs under `bypassPermissions`. Widening or tightening it
        // is a separate change with its own measurement.
        let repo = repo()
        let invocation = RunScheduler.invocation(
            for: run(.analyzeRepo, repoID: repo.id), repo: repo, perRunUSD: nil)
        #expect(invocation.permissionMode == .bypassPermissions)
        #expect(invocation.extraDirectories.isEmpty)
    }

    @Test("A repository already tighter than the cap keeps its own mode")
    func aTighterRepositoryIsRespected() {
        let repo = repo(.plan)
        let invocation = RunScheduler.invocation(
            for: run(.appraiseCards, repoID: repo.id), repo: repo, perRunUSD: nil)
        #expect(invocation.permissionMode == .plan)
    }

    @Test("The per-run ceiling still reaches the argv")
    func theBudgetSurvives() {
        let repo = repo()
        let invocation = RunScheduler.invocation(
            for: run(.appraiseCards, repoID: repo.id), repo: repo, perRunUSD: 0.5)
        #expect(invocation.arguments().contains("--max-budget-usd"))
    }

    /// ⛔ The two facts PR3 put in this literal, pinned where the extraction can
    /// no longer drop them.
    ///
    /// Extracting a body is exactly the moment a value gets retyped from the
    /// nearest plausible source, and both of these have a plausible wrong
    /// source three characters away: `repo.path` for the cwd, and nothing at
    /// all for the fork. Neither loss is visible in any other assertion here —
    /// every other test in this suite uses a run whose `cwd` *equals*
    /// `repo.path` and which resumes nothing.
    @Test("A run is spawned in its own directory, not its repository's")
    func theRunsOwnDirectoryIsCarried() {
        let repo = repo()
        var subject = run(.implementIssue, repoID: repo.id)
        // The shape of a resumed run: the first attempt's directory, which the
        // repository may since have been re-registered away from. Claude Code
        // keeps a transcript under a slug of the directory the session ran in,
        // so spawning anywhere else answers "No conversation found" — which
        // reads as an expired session rather than a wrong directory.
        subject.cwd = "/tmp/where-the-first-attempt-ran"
        let invocation = RunScheduler.invocation(for: subject, repo: repo, perRunUSD: nil)
        #expect(invocation.cwd == "/tmp/where-the-first-attempt-ran")
        #expect(invocation.cwd != repo.path)
    }

    @Test("A resumed run still forks the session it resumed from")
    func theForkSurvivesTheExtraction() {
        let repo = repo()
        var subject = run(.implementIssue, repoID: repo.id)
        let earlier = UUID()
        subject.resumedFrom = earlier
        let invocation = RunScheduler.invocation(for: subject, repo: repo, perRunUSD: nil)
        #expect(invocation.resumeFrom == earlier)
        #expect(invocation.arguments().contains("--fork-session"))
    }

    @Test("The repository's extra allowed tools still reach an appraisal")
    func extraAllowedToolsSurvive() {
        var repo = repo()
        repo.extraAllowedTools = ["Read"]
        let invocation = RunScheduler.invocation(
            for: run(.appraiseCards, repoID: repo.id), repo: repo, perRunUSD: nil)
        #expect(invocation.extraAllowedTools == ["Read"])
    }

    /// ⛔ `--add-dir` on a path that does not exist grants nothing.
    ///
    /// `StoreLocation.ensureDirectories()` creates `home`, `runs`, `analyses`
    /// and `screenshots` — measured, and **not** `analyses/appraisals/<runID>`.
    /// So the grant above is inert unless something creates the directory
    /// before the child starts, and the symptom of forgetting is the agent
    /// reporting it could not write its artifact: a failure that reads as the
    /// agent's, one layer away from the grant that looks perfectly correct.
    ///
    /// Driven through a real spawn rather than by calling the creating function
    /// directly, because the claim worth pinning is that `start` performs it —
    /// a directory-making function nothing calls is the defect, not the fix.
    @Test("An appraisal's artifact directory exists by the time the child spawns")
    func theArtifactDirectoryIsCreatedBeforeTheSpawn() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let checkout = TestHome.scratch("appraisal-spawn")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: checkout) }

        let store = try BoardStore.inMemory()
        let config = ToolConfig(
            claudePath: root.appendingPathComponent("Scripts/fake-claude.sh").path,
            ghPath: "/usr/bin/true", gitPath: "/usr/bin/true",
            environment: [
                // `ToolConfig.environment` *replaces* the child's environment
                // rather than extending it, and the fake shells out.
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "FAKE_CLAUDE_FIXTURE": root
                    .appendingPathComponent("Fixtures/stream-json/analyze-success.ndjson").path,
            ]
        )
        // A directory that genuinely exists: `Process` sets the child's working
        // directory on the spawn, so a path pointing at nothing makes
        // `ClaudeRun.start` throw and the run fails without ever spawning —
        // which is the one way this test could pass for the wrong reason.
        let subjectRepo = Repo(
            path: checkout.path, nameWithOwner: "phmatray/Elliot",
            defaultBranch: "main", displayName: "Elliot"
        )
        try await store.saveRepo(subjectRepo)
        let card = Card(
            repoID: subjectRepo.id, title: "a card",
            columnEnteredAt: now, createdAt: now, updatedAt: now
        )
        try await store.saveCard(card)

        let runID = UUID()
        let directory = StoreLocation.appraisalRunDirectory(runID: runID)
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        try await store.saveRun(SkillRun(
            id: runID, cardID: card.id, repoID: subjectRepo.id, kind: .appraiseCards,
            prompt: "appraise", cwd: checkout.path,
            logPath: StoreLocation.runLogURL(runID: runID).path,
            stderrPath: StoreLocation.runStderrURL(runID: runID).path,
            createdAt: now
        ))

        let scheduler = RunScheduler(
            store: store, toolConfig: config, verifier: Verifier(gh: .init(config: config))
        )
        await scheduler.launch(runID: runID)
        // Bounded, and on a fact rather than a duration: the row reaching a
        // terminal state is the proof the child ran to completion.
        try await withTimeout(.seconds(20)) {
            while true {
                if try await store.run(id: runID)?.state.isActive == false { return }
                await Task.yield()
            }
        }

        #expect(FileManager.default.fileExists(atPath: directory.path))
        // Owner-only, like every directory `ensureDirectories` makes: these sit
        // under `ELLIOT_HOME`, beside the socket and the token.
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect(attributes[.posixPermissions] as? NSNumber == 0o700)
        // And it is the directory the run was actually granted, not merely a
        // directory of the same name: the argv recorded on the row is what the
        // child was handed.
        let finished = try #require(try await store.run(id: runID))
        #expect(finished.argv.contains(directory.path))
        // ⚠️ The preparation happens on the way to the spawn, so a child that
        // never started would leave the directory behind all the same and this
        // test would pass for the one reason it must not. A run that really ran
        // is the guard: `ClaudeRun.start` throwing lands the row on `.failed`
        // with no exit code at all.
        #expect(finished.state == .succeeded)
        #expect(finished.exitCode == 0)
    }
}
