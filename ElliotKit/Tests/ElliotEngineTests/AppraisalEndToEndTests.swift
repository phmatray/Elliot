import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import TestSupport
import Testing

@testable import ElliotEngine

/// Duplicated rather than shared with the other end-to-end suites: a private
/// enum in one test file is not visible from another, and one small repetition
/// beats a shared helper target for three constants.
private enum TestPaths {
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let fakeClaude = repoRoot.appendingPathComponent("Scripts/fake-claude.sh").path

    static func streamFixture(_ name: String) -> String {
        repoRoot.appendingPathComponent("Fixtures/stream-json/\(name)").path
    }

    static func appraisalFixture(_ name: String) -> String {
        repoRoot.appendingPathComponent("Fixtures/appraisal/\(name)").path
    }
}

extension EndToEndSuites {

/// The appraisal from end to end: a card, a real spawn of the fake `claude`, the
/// artifact it drops at the path the prompt announced, and the three fields that
/// land on the card.
///
/// `.serialized` under `EndToEndSuites` for the reason the others are: they share
/// a process-global `ELLIOT_HOME` and must not run at the same time.
@Suite("Appraisal end to end", .serialized)
struct AppraisalEndToEndTests {

    private struct Stack {
        var store: BoardStore
        var board: BoardService
        var scheduler: RunScheduler
        var service: AppraisalService
        var repo: Repo
        var card: Card
        var home: URL
        /// The second database the injected `AppraisalHarvester` writes into,
        /// when this stack was built with one. `nil` for every other test, which
        /// lets the scheduler default its own harvester off `store`.
        var shadow: BoardStore?

        /// Removes this test's own directory only. The shared `ELLIOT_HOME`
        /// above it stays: another suite may still be writing into it.
        func cleanUp() { try? FileManager.default.removeItem(at: home) }

        /// Bounded, and it waits on a **fact** — the run reaching a terminal
        /// state — rather than on a duration.
        func awaitRun(id: UUID, timeout: Duration = .seconds(30)) async throws -> SkillRun {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while ContinuousClock.now < deadline {
                if let run = try await store.run(id: id), run.state.isTerminal { return run }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw StackError.timedOut
        }

        enum StackError: Error { case timedOut }
    }

    /// - Parameters:
    ///   - artifact: the JSON the fake tool drops at the path the prompt
    ///     announced. `nil` leaves `FAKE_CLAUDE_STORIES` unset, which is the
    ///     shape of a run that talked and wrote nothing.
    ///   - gitPath: defaults to a binary that always fails, matching every other
    ///     end-to-end stack. `GitClient.porcelainStatus` swallows a failing
    ///     `git` into `""`, so the sentinel then compares two swallowed failures
    ///     and calls the coincidence "clean" — a caller that wants it to say
    ///     anything real must pass a working `git` and `git init` the fixture
    ///     repo, exactly as `AnalysisEndToEndTests` does.
    ///   - harvestInto: names a **second** database, seeded with this same
    ///     repository and card, and hands the scheduler an `AppraisalHarvester`
    ///     over it through `RunScheduler.init(appraiser:)`. The harvest then
    ///     lands there instead of in `store`, which is the only externally
    ///     visible thing that seam can change.
    private func makeStack(
        artifact: String? = TestPaths.appraisalFixture("e2e-small.json"),
        extraEnv: [String: String] = [:],
        gitPath: String = "/usr/bin/false",
        harvestInto shadowName: String? = nil
    ) async throws -> Stack {
        let home = TestHome.scratch("appraisal-e2e")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try StoreLocation.ensureDirectories()

        // A throwaway checkout with one real file, so evidence resolution has
        // something true and something false to tell apart.
        let repoRoot = home.appendingPathComponent("repo", isDirectory: true)
        let sources = repoRoot.appendingPathComponent("Sources/ElliotProcess", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "// real".write(
            to: sources.appendingPathComponent("ClaudeRunner.swift"),
            atomically: true, encoding: .utf8
        )

        let store = try BoardStore.open(at: home.appendingPathComponent("elliot.sqlite"))

        // Built before the scheduler, because the shadow store below has to hold
        // the *same* rows and the scheduler has to be handed a harvester over it.
        let repo = Repo(
            path: repoRoot.path, nameWithOwner: "phmatray/Elliot", displayName: "Elliot"
        )
        let now = Date()
        let card = Card(
            repoID: repo.id, title: "The idle watchdog outlives a cancelled run",
            story: UserStory(
                role: "developer", want: "the idle task cancelled on every exit path",
                benefit: "a cancelled run stops waking the machine every 30 seconds"),
            columnEnteredAt: now, createdAt: now, updatedAt: now
        )

        var shadow: BoardStore?
        if let shadowName {
            let second = try BoardStore.open(
                at: home.appendingPathComponent("\(shadowName).sqlite"))
            // The repository first: `card.repoID` is a foreign key.
            try await second.saveRepo(repo)
            try await second.saveCard(card)
            shadow = second
        }

        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        environment["FAKE_CLAUDE_FIXTURE"] = TestPaths.streamFixture("analyze-success.ndjson")
        if let artifact {
            // Named for the analysis, but what it does is copy a file to the
            // path the prompt announced after `ELLIOT_OUTPUT=` — which is the
            // appraisal's contract too, because the marker is shared.
            environment["FAKE_CLAUDE_STORIES"] = artifact
        }
        environment.merge(extraEnv) { _, new in new }

        let config = ToolConfig(
            claudePath: TestPaths.fakeClaude,
            ghPath: "/usr/bin/false",
            gitPath: gitPath,
            environment: environment
        )
        let scheduler = RunScheduler(
            store: store, toolConfig: config, verifier: Verifier(gh: .init(config: config)),
            appraiser: shadow.map { AppraisalHarvester(store: $0) }
        )
        let board = BoardService(store: store, launcher: scheduler)
        await scheduler.setSystemMover(board)

        try await store.saveRepo(repo)
        try await store.saveCard(card)

        return Stack(
            store: store, board: board, scheduler: scheduler,
            service: AppraisalService(store: store, launcher: scheduler, gate: OpenGate()),
            repo: repo, card: card, home: home, shadow: shadow
        )
    }

    /// `git init`s the fixture checkout, so the sentinel has a real tree to read.
    ///
    /// Through `TestSupport`'s `git`, which **throws** on a non-zero exit. The
    /// `_ = try? await ProcessRunner.run(…)` this replaced discarded exactly
    /// that, and the discard was not harmless: with no repository to read,
    /// `GitClient.porcelainStatus` swallows the failing `git` into `""` at both
    /// ends, so the sentinel below compared two swallowed failures and called
    /// the coincidence "clean". A set-up that cannot speak makes the assertion
    /// after it vacuous.
    private func initGit(at path: String) async throws {
        try await git(["init", "-q"], in: path)
    }

    /// - Note: `.enabled(if: gitFixtureIsAvailable)` rather than a branch inside
    ///   the body. The sentinel block below used to sit behind `if git != nil`,
    ///   so on a machine without `/usr/bin/git` this test reported green having
    ///   asserted the one thing #368's review demanded — and a skip that leaves
    ///   no trace in the output is indistinguishable from a pass. The trait is
    ///   named in the run; the branch was not.
    @Test(
        "An appraisal fills the card in, from the artifact it was told to write",
        .enabled(if: gitFixtureIsAvailable))
    func theWholePath() async throws {
        let stack = try await makeStack(gitPath: gitFixturePath)
        defer { stack.cleanUp() }
        try await initGit(at: stack.repo.path)

        let started = try await stack.service.appraise(cardID: stack.card.id)
        let run = try await withTimeout(.seconds(40)) {
            try await stack.awaitRun(id: started.id)
        }

        #expect(run.state == .succeeded)
        #expect(run.exitCode == 0)
        #expect(run.kind == .appraiseCards)

        // Harvested from the artifact, not from prose. The whole point.
        let report = try #require(run.analysisReport)
        #expect(report.harvestSource == .artifact)
        #expect(report.kept == 1)
        #expect(report.dropped.isEmpty)

        // Checked-and-clean, not "never checked": a real `git status` was taken
        // before and after, over an actually-initialised repo, and found
        // nothing — `false`, not `nil`. The artifact lands under the shared
        // `TestHome.root`, not inside the checkout, so a regression that made an
        // appraisal touch the repository would flip this.
        //
        // ⛔ This assertion is the one the appraisal half of the sentinel did
        // not have. Passing `baseline: nil` into `completeAppraisalRun` left the
        // whole suite green while the identical break on the analysis half
        // reddened three tests; the card still comes out appraised either way,
        // so nothing else here can see it. It is unconditional for the same
        // reason: guarded by `if git != nil` it was one absent binary away from
        // being back where it started.
        #expect(report.workingTreeChanged == false)
        #expect(report.workingTreeDiff == nil)

        // The artifact really is where the prompt said it would be.
        #expect(FileManager.default.fileExists(
            atPath: StoreLocation.appraisalArtifactURL(runID: run.id).path))

        let card = try #require(try await stack.store.card(id: stack.card.id))
        #expect(card.effort == .small)
        #expect(card.appraisedAt != nil)
        let evidence = try #require(card.evidence)
        #expect(evidence.count == 2)
        #expect(evidence[0].path == "Sources/ElliotProcess/ClaudeRunner.swift")
        #expect(evidence[0].line == 159)
        #expect(evidence[0].exists)
        // The cited file that is not there is marked, not dropped: it is the
        // fastest signal that a citation was invented.
        #expect(evidence[1].exists == false)

        // And the card did not move. An appraisal is not a transition.
        #expect(card.column == .backlog)
        #expect(card.issueNumber == nil)
        #expect(card.lastError == nil)
    }

    /// - Note: a real `git` is needed for the sentinel to say anything, and it
    ///   is required as a trait rather than checked as a `guard … else
    ///   { return }`. Without one, the early return reported this test green
    ///   having asserted nothing at all.
    @Test(
        "An appraisal that edits the repository is reported, not hidden",
        .enabled(if: gitFixtureIsAvailable))
    func theSentinelFires() async throws {
        let stack = try await makeStack(
            extraEnv: ["FAKE_CLAUDE_TOUCH": "meddled.txt"], gitPath: gitFixturePath
        )
        defer { stack.cleanUp() }
        try await initGit(at: stack.repo.path)

        let started = try await stack.service.appraise(cardID: stack.card.id)
        let run = try await withTimeout(.seconds(40)) {
            try await stack.awaitRun(id: started.id)
        }
        let report = try #require(run.analysisReport)

        // The other direction of the same guard. `workingTreeChanged == false`
        // above would still pass if the sentinel had been wired to answer a
        // constant; this one only passes if it really reads the tree twice.
        #expect(report.workingTreeChanged == true)
        #expect(report.workingTreeDiff?.contains("meddled.txt") == true)
        // And the appraisal still lands — the sentinel reports, it does not
        // punish. An appraisal dropped on a dirty tree would be a second,
        // unwritten rule.
        #expect(report.harvestSource == .artifact)
        #expect(report.kept == 1)
        #expect(try await stack.store.card(id: stack.card.id)?.effort == .small)
    }

    @Test("The card is free again once the run has finished")
    func theCardIsReleased() async throws {
        let stack = try await makeStack()
        defer { stack.cleanUp() }

        let started = try await stack.service.appraise(cardID: stack.card.id)
        _ = try await withTimeout(.seconds(40)) { try await stack.awaitRun(id: started.id) }

        #expect(try await stack.store.activeRun(cardID: stack.card.id) == nil)
        // The ownership is a hold, not a lock: once the run is terminal the card
        // moves like any other, through the same funnel.
        let result = try await stack.board.move(
            cardID: stack.card.id, to: .todo, origin: .userDrag, requiresVerifiedGreen: false)
        guard case .moved(let runID?) = result else {
            Issue.record("expected a run, got \(result)")
            return
        }
        #expect(try await stack.store.run(id: runID)?.kind == .createIssue)
        // And the appraisal survived the move, which writes the whole card row.
        let card = try #require(try await stack.store.card(id: stack.card.id))
        #expect(card.effort == .small)
        #expect(card.appraisedAt != nil)
    }

    @Test("The spawn really carries the tighter mode and the artifact directory")
    func theArgvIsTightened() async throws {
        let argvOut = TestHome.scratch("appraisal-argv").path
        let stack = try await makeStack(extraEnv: ["FAKE_CLAUDE_ARGV_OUT": argvOut])
        defer { stack.cleanUp() }
        defer { try? FileManager.default.removeItem(atPath: argvOut) }

        let started = try await stack.service.appraise(cardID: stack.card.id)
        _ = try await withTimeout(.seconds(40)) { try await stack.awaitRun(id: started.id) }

        let argv = try String(contentsOfFile: argvOut, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        // Asserted against what the process was actually given, not against
        // `ClaudeInvocation` — the unit test already pins that, and this is the
        // only thing that proves the scheduler passes it through.
        let modeIndex = try #require(argv.firstIndex(of: "--permission-mode"))
        #expect(argv[modeIndex + 1] == "acceptEdits")
        #expect(!argv.contains("bypassPermissions"))

        let directories = argv.enumerated()
            .filter { $0.element == "--add-dir" }
            .map { argv[$0.offset + 1] }
        #expect(directories == [
            stack.repo.path,
            StoreLocation.appraisalRunDirectory(runID: started.id).path,
        ])
    }

    @Test("A run that writes no artifact leaves the card unappraised, and says so")
    func noArtifactLeavesTheCardAlone() async throws {
        // No `FAKE_CLAUDE_STORIES`, so the fake tool replays its stream and
        // drops nothing — the shape of a run that talked and wrote nothing.
        let stack = try await makeStack(artifact: nil)
        defer { stack.cleanUp() }

        let started = try await stack.service.appraise(cardID: stack.card.id)
        let run = try await withTimeout(.seconds(40)) {
            try await stack.awaitRun(id: started.id)
        }

        #expect(run.state == .succeeded)
        let report = try #require(run.analysisReport)
        #expect(report.harvestSource == .none)
        #expect(report.kept == 0)
        #expect(report.dropped.contains { $0.contains("No artifact was written") })

        let card = try #require(try await stack.store.card(id: stack.card.id))
        #expect(card.appraisedAt == nil)
        #expect(card.effort == nil)
        #expect(card.evidence == nil)
    }

    @Test("A malformed artifact leaves the card unappraised, and says what was wrong")
    func malformedArtifactLeavesTheCardAlone() async throws {
        let stack = try await makeStack(
            artifact: TestPaths.appraisalFixture("not-an-object.json"))
        defer { stack.cleanUp() }

        let started = try await stack.service.appraise(cardID: stack.card.id)
        let run = try await withTimeout(.seconds(40)) {
            try await stack.awaitRun(id: started.id)
        }

        let report = try #require(run.analysisReport)
        #expect(report.harvestSource == .none)
        #expect(report.dropped.contains { $0.contains("not a JSON object") })
        #expect(try await stack.store.card(id: stack.card.id)?.appraisedAt == nil)
    }

    @Test("An appraisal starts against a full writer lane, in a real drain")
    func theLaneIsRealAndNotOnlyAdmission() async throws {
        // `SchedulerReadOnlyLaneTests` asks `refusal(for:)` directly. This asks
        // `pump()` — the caller — with the writer cap at one and a writer really
        // in flight, because a lane that is right in `refusal` and wrong in the
        // drain is a lane that does not exist.
        //
        // The writer is seeded rather than dragged. One `ToolConfig` serves the
        // whole stack, so `FAKE_CLAUDE_MODE=hang` would hang the appraisal too
        // and the test would prove the opposite of its name;
        // `testOnlyMarkInFlight` puts a writer in the set `refusal` reads
        // without spawning anything, which is exactly the state under test.
        let stack = try await makeStack()
        defer { stack.cleanUp() }
        await stack.scheduler.setLimits(
            SchedulerLimits(maxConcurrent: 1, maxConcurrentAnalyses: 2))

        let now = Date()
        let busy = Card(
            repoID: stack.repo.id, title: "Something else",
            story: UserStory(role: "dev", want: "w", benefit: "b"),
            columnEnteredAt: now, createdAt: now, updatedAt: now
        )
        try await stack.store.saveCard(busy)

        var writer = SkillRun.card(
            cardID: busy.id, repoID: stack.repo.id, kind: .implementIssue, prompt: "x",
            cwd: stack.repo.path, logPath: "/tmp/w.ndjson", stderrPath: "/tmp/w.log",
            createdAt: now
        )
        writer.state = .running
        await stack.scheduler.testOnlyMarkInFlight(writer)

        // The writer lane is full — proved, not assumed. Without this the rest
        // of the test would pass against an empty scheduler and measure nothing.
        var second = SkillRun.card(
            cardID: UUID(), repoID: stack.repo.id, kind: .implementIssue, prompt: "x",
            cwd: stack.repo.path, logPath: "/tmp/s.ndjson", stderrPath: "/tmp/s.log",
            createdAt: now
        )
        second.state = .queued
        #expect(
            await stack.scheduler.refusal(for: second, overBudget: false)
                == .writerCapReached(inFlight: 1, cap: 1)
        )

        // And the appraisal goes through the real drain anyway.
        let started = try await stack.service.appraise(cardID: stack.card.id)
        let run = try await withTimeout(.seconds(40)) {
            try await stack.awaitRun(id: started.id)
        }
        #expect(run.state == .succeeded)
        #expect(try await stack.store.card(id: stack.card.id)?.effort == .small)
    }

    /// `RunScheduler.init(appraiser:)`, exercised — it had no caller anywhere in
    /// `Sources/` or `Tests/`.
    ///
    /// A parameter with readers and no writer is a shape this repository has
    /// already paid for twice: `Repo.permissionMode`, readable everywhere and
    /// writable nowhere for the whole life of the project, and
    /// `PreflightService.isBlocking`, asserted in three documents and
    /// implemented in none.
    ///
    /// ⚠️ **`AppraisalHarvester` is a struct, so this seam cannot carry a spy.**
    /// The one thing an injected harvester can differ in is *which store the
    /// three fields land in* — so that is what is varied here: a second database
    /// holding the same repository and the same card. Both halves of the
    /// assertion flip if `init` stops honouring the parameter.
    ///
    /// ⚠️ **And it cannot deliver what its own doc comment promises** — "a test
    /// that wants to watch the harvest happen should not have to spawn a
    /// `claude`". `completeAppraisalRun` is private and reached only through
    /// `finish`, which is reached only through a real spawn. This test spawns
    /// one, like every other test in this suite.
    @Test("The harvest lands in the appraiser the scheduler was handed")
    func theInjectedAppraiserIsTheOneThatWrites() async throws {
        let stack = try await makeStack(harvestInto: "shadow")
        defer { stack.cleanUp() }
        let shadow = try #require(stack.shadow)

        let started = try await stack.service.appraise(cardID: stack.card.id)
        let run = try await withTimeout(.seconds(40)) {
            try await stack.awaitRun(id: started.id)
        }

        // The harvest ran, and succeeded — read off the run row in the
        // scheduler's own store, which is where the report always lands.
        let report = try #require(run.analysisReport)
        #expect(report.harvestSource == .artifact)
        #expect(report.kept == 1)

        // The three fields went into the injected store.
        let harvested = try #require(try await shadow.card(id: stack.card.id))
        #expect(harvested.effort == .small)
        #expect(harvested.appraisedAt != nil)
        #expect(harvested.evidence?.count == 2)

        // And not into the scheduler's own, which is the half that proves the
        // parameter is load-bearing rather than decorative.
        let untouched = try #require(try await stack.store.card(id: stack.card.id))
        #expect(untouched.effort == nil)
        #expect(untouched.appraisedAt == nil)
        #expect(untouched.evidence == nil)
    }
}

}  // extension EndToEndSuites
