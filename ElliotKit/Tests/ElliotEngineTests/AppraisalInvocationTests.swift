import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import TestSupport
import Testing

@testable import ElliotEngine

/// What a run is spawned with, decided in one pure function so it can be asserted without
/// spawning anything.
///
/// Two facts differ for an appraisal — a tighter permission mode, and the one directory outside
/// the checkout it must be allowed to write — and they travel together here rather than as two
/// `if`s inside a spawn routine, where only one of them would be remembered next time.
///
/// ⚠️ **These assertions used to read `invocation.arguments()`, and that function no longer
/// exists.** `AgentInvocation` renders no flags at all: `cwd` and `extraDirectories` become
/// `session/new`'s `cwd` and `additionalDirectories`, `permissionMode` a
/// `session/set_config_option`, `maxBudgetUSD` a live brake, and `resumeFromAgentSession` a
/// `session/fork`. So each assertion below moved onto the field the wire actually carries —
/// which is nearer the fact than counting `--add-dir` occurrences ever was.
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

    @Test("A writer is spawned exactly as it was: the repository's mode, its own directory only")
    func writersAreUnchanged() {
        let repo = repo()
        let invocation = RunScheduler.invocation(
            for: run(.implementIssue, repoID: repo.id), repo: repo, perRunUSD: nil,
            resumingAgentSession: nil)
        #expect(invocation.permissionMode == .bypassPermissions)
        // The checkout it runs in is `cwd`, and nothing beyond it is granted. Under `claude -p`
        // this was "exactly one `--add-dir`", the flag that carried `cwd`; the count moved when
        // the concept did.
        #expect(invocation.extraDirectories.isEmpty)
        #expect(invocation.cwd == "/tmp/checkout")
    }

    @Test("An appraisal is spawned tighter than its repository")
    func appraisalIsTightened() {
        let repo = repo()
        let invocation = RunScheduler.invocation(
            for: run(.appraiseCards, repoID: repo.id), repo: repo, perRunUSD: nil,
            resumingAgentSession: nil)
        // Not `bypassPermissions`: a denied tool is the whole point. Under the
        // default the MCP self-call is granted in silence and the run ends
        // "success" having driven the board.
        #expect(invocation.permissionMode == .acceptEdits)
        // And it survives the trip to the adapter's own vocabulary, which is where the mode
        // actually lands now.
        #expect(AgentInvocation.configValue(for: invocation.permissionMode) == "acceptEdits")
    }

    @Test("An appraisal may write its artifact directory, and only that")
    func appraisalCarriesItsArtifactDirectory() throws {
        _ = TestHome.root
        let repo = repo()
        let subject = run(.appraiseCards, repoID: repo.id)
        let invocation = RunScheduler.invocation(
            for: subject, repo: repo, perRunUSD: nil, resumingAgentSession: nil)

        let expected = StoreLocation.appraisalRunDirectory(runID: subject.id).path
        #expect(invocation.extraDirectories == [expected])
        // Beside its own checkout, never instead of it — `session/new` carries the two
        // separately, so a grant that replaced `cwd` would leave the run unable to read the
        // repository it is appraising.
        #expect(invocation.cwd == subject.cwd)
    }

    @Test("An analysis is not tightened by this change")
    func analysesAreUntouched() {
        // Deliberate, and out of scope: an analysis writes its artifact today
        // because it runs under `bypassPermissions`. Widening or tightening it
        // is a separate change with its own measurement.
        let repo = repo()
        let invocation = RunScheduler.invocation(
            for: run(.analyzeRepo, repoID: repo.id), repo: repo, perRunUSD: nil,
            resumingAgentSession: nil)
        #expect(invocation.permissionMode == .bypassPermissions)
        #expect(invocation.extraDirectories.isEmpty)
    }

    @Test("A repository already tighter than the cap keeps its own mode")
    func aTighterRepositoryIsRespected() {
        let repo = repo(.plan)
        let invocation = RunScheduler.invocation(
            for: run(.appraiseCards, repoID: repo.id), repo: repo, perRunUSD: nil,
            resumingAgentSession: nil)
        #expect(invocation.permissionMode == .plan)
    }

    @Test("The per-run ceiling still reaches the invocation")
    func theBudgetSurvives() {
        let repo = repo()
        let invocation = RunScheduler.invocation(
            for: run(.appraiseCards, repoID: repo.id), repo: repo, perRunUSD: 0.5,
            resumingAgentSession: nil)
        // `--max-budget-usd` went with the CLI; the ceiling is a live brake on `usage_update`
        // now, and this is the value it brakes against. ⚠️ A brake, not a guarantee — see
        // `AgentInvocation.maxBudgetUSD`.
        #expect(invocation.maxBudgetUSD == 0.5)
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
        let invocation = RunScheduler.invocation(
            for: subject, repo: repo, perRunUSD: nil, resumingAgentSession: nil)
        #expect(invocation.cwd == "/tmp/where-the-first-attempt-ran")
        #expect(invocation.cwd != repo.path)
    }

    /// ⚠️ **The fork's anchor changed type, and that is the substance rather than a rename.**
    /// `--resume <id> --fork-session` took `SkillRun.id`, because `claude -p` was handed that id
    /// as `--session-id` and the two were one value. `session/fork` takes the **agent's** own
    /// session id, which the agent chose and which lives on the predecessor row. So this function
    /// can no longer derive the anchor from `run.resumedFrom` at all — it is passed in, and
    /// `RunScheduler.start` is what reads the predecessor.
    @Test("A resumed run forks the agent session it was given")
    func theForkSurvivesTheExtraction() {
        let repo = repo()
        var subject = run(.implementIssue, repoID: repo.id)
        subject.resumedFrom = UUID()
        let invocation = RunScheduler.invocation(
            for: subject, repo: repo, perRunUSD: nil,
            resumingAgentSession: "sess-the-first-attempt")
        #expect(invocation.resumeFromAgentSession == "sess-the-first-attempt")
    }

    /// The other half, and the one a `resumedFrom`-driven implementation would get wrong: a
    /// predecessor that never reached `session/new` has no agent session, so there is nothing to
    /// fork and the run must start fresh rather than fork a nil.
    @Test("A run resuming an attempt with no agent session forks nothing")
    func aResumeWithNoAnchorForksNothing() {
        let repo = repo()
        var subject = run(.implementIssue, repoID: repo.id)
        subject.resumedFrom = UUID()
        let invocation = RunScheduler.invocation(
            for: subject, repo: repo, perRunUSD: nil, resumingAgentSession: nil)
        #expect(invocation.resumeFromAgentSession == nil)
    }

    @Test("The repository's extra allowed tools still reach an appraisal")
    func extraAllowedToolsSurvive() {
        var repo = repo()
        repo.extraAllowedTools = ["Read"]
        let invocation = RunScheduler.invocation(
            for: run(.appraiseCards, repoID: repo.id), repo: repo, perRunUSD: nil,
            resumingAgentSession: nil)
        // ⚠️ Reaching the invocation is now where this stops: there is no ACP config option for
        // allowed tools, so `AgentRun.start` **refuses** rather than dropping the grant. That
        // refusal is `ACPRunnerTests`'; what this pins is that the value is still carried to it,
        // because a grant silently emptied here would refuse nothing and grant nothing.
        #expect(invocation.extraAllowedTools == ["Read"])
    }

    /// ⛔ A granted directory that does not exist grants nothing.
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

        // Where the double records what `session/new` was actually asked for. The argv it used to
        // be asserted on is gone: `AgentInvocation.displayArgv` is the adapter's three tokens for
        // every run, so the directories moved onto the wire. This reads them off the wire.
        let sessionOut = checkout.appendingPathComponent("session-new.json")

        let store = try BoardStore.inMemory()
        let config = ToolConfig(
            adapterExecutable: "/usr/bin/env",
            adapterArguments: ["python3", root.appendingPathComponent("Scripts/fake-acp.py").path],
            ghPath: "/usr/bin/true", gitPath: "/usr/bin/true",
            environment: [
                // `ToolConfig.environment` *replaces* the child's environment
                // rather than extending it, and the double needs a `python3`.
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "FAKE_ACP_FIXTURE": root
                    .appendingPathComponent("Fixtures/acp/fake-simple-turn.json").path,
                "FAKE_ACP_SESSION_OUT": sessionOut.path,
            ]
        )
        // A directory that genuinely exists: `Process` sets the child's working
        // directory on the spawn, so a path pointing at nothing makes
        // `AgentRun.start` throw and the run fails without ever spawning —
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
        // And it is the directory the run was actually **granted**, not merely a directory of the
        // same name. Read off the `session/new` the agent received, which is a stronger witness
        // than the old argv assertion: argv proved what Elliot spelled, this proves what the
        // agent was handed.
        let asked = try JSONSerialization.jsonObject(
            with: Data(contentsOf: sessionOut)) as? [String: Any]
        #expect(asked?["additionalDirectories"] as? [String] == [directory.path])
        #expect(asked?["cwd"] as? String == checkout.path)
        // ⚠️ The preparation happens on the way to the spawn, so a child that
        // never started would leave the directory behind all the same and this
        // test would pass for the one reason it must not. A run that really ran
        // is the guard: `AgentRun.start` throwing lands the row on `.failed`
        // with no exit code at all.
        let finished = try #require(try await store.run(id: runID))
        #expect(finished.state == .succeeded)
        #expect(finished.exitCode == 0)
    }
}
