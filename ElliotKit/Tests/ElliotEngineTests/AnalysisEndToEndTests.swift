import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine

/// Duplicated rather than shared with `EndToEndTests`: a private enum in one
/// test file is not visible from another, and one small repetition beats a
/// shared helper target for two constants.
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

    static func analysisFixture(_ name: String) -> String {
        repoRoot.appendingPathComponent("Fixtures/analysis/\(name)").path
    }
}

/// One `ELLIOT_HOME` for the whole test process, set once and never removed.
///
/// `StoreLocation` reads the variable on every access and it is process-global,
/// so a per-test home that gets deleted at the end of one test pulls the ground
/// out from under any suite still writing run logs. Both end-to-end suites are
/// nested under one `.serialized` parent for the same reason.
///
/// **The only thing in this test target permitted to touch `ELLIOT_HOME`.**
/// Swift Testing runs independent suites in parallel, so two lazy statics each
/// racing to `setenv` their own idea of the home is exactly the hazard this
/// type exists to remove: whichever wins, a suite already under way sees its
/// path prefix change from underneath it. The next suite that needs a home
/// reaches for `TestHome.scratch(_:)` rather than rolling its own `setenv`.
///
/// This also fixes something that was already true: without it, the existing
/// end-to-end suite writes its run logs into the real
/// `~/Library/Application Support/Elliot/runs`.
enum TestHome {
    /// Swift runs a `static let`'s initialiser at most once, even if two
    /// suites reach for `root` at the same instant, which is what lets this
    /// safely `setenv` before either test body can observe `ELLIOT_HOME`.
    static let root: URL = {
        // An operator's own `ELLIOT_HOME`, already exported before `swift
        // test` ran, is adopted rather than clobbered — `StoreLocation`
        // documents that override as absolute, and honouring it here is what
        // keeps this the *only* setter: a second lazy static elsewhere that
        // still finds it unset would otherwise race this one. The trade is
        // that a pre-set value without a space in it leaves the space-parsing
        // assertions below exercising less than they would under our own
        // default — an operator's explicit choice, not a silent gap.
        if let existing = ProcessInfo.processInfo.environment["ELLIOT_HOME"], !existing.isEmpty {
            let url = URL(fileURLWithPath: existing, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elliot-tests-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
            // Two spaces, deliberately, and not for decoration: this is the
            // shape of Elliot's real default home
            // (`~/Library/Application Support/Elliot`), and it is exactly what
            // a `sed` that stops at the first whitespace character truncates.
            // A home without a space in it would let that bug pass this suite
            // and ship anyway — see commit 06993ad and Scripts/fake-claude.sh.
            .appendingPathComponent("Application  Support", isDirectory: true)
            .appendingPathComponent("Elliot", isDirectory: true)
        setenv("ELLIOT_HOME", url.path, 1)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// A directory of one test's own, inside the shared home. Safe to delete:
    /// nothing else writes here.
    static func scratch(_ label: String) -> URL {
        _ = root
        return root.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    }
}

/// Both end-to-end suites nested under one serialized parent. They share a
/// process-global `ELLIOT_HOME`, so they must not run at the same time.
@Suite("End to end", .serialized)
struct EndToEndSuites {}

extension EndToEndSuites {

@Suite("Analysis end to end", .serialized)
struct AnalysisEndToEndTests {

    private struct Stack {
        var store: BoardStore
        var board: BoardService
        var scheduler: RunScheduler
        var analysisService: AnalysisService
        var repo: Repo
        var home: URL

        /// Removes this test's own directory only. The shared `ELLIOT_HOME`
        /// above it stays: another suite may still be writing into it.
        func cleanUp() { try? FileManager.default.removeItem(at: home) }

        func awaitRuns(analysisID: UUID, timeout: Duration = .seconds(30)) async throws -> [SkillRun] {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while ContinuousClock.now < deadline {
                let runs = try await store.runs(analysisID: analysisID)
                if !runs.isEmpty, runs.allSatisfy({ $0.state.isTerminal }) { return runs }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw StackError.timedOut
        }

        enum StackError: Error { case timedOut }
    }

    /// The prompt, the fake tool and the harvester must agree on one artifact
    /// path, and that agreement is what is under test — so `StoreLocation` has
    /// to resolve somewhere writable. `TestHome` provides that once for the
    /// process; this test only owns a scratch directory inside it.
    ///
    /// The database is explicitly per-test: `StoreLocation.databaseURL` is
    /// shared now, and two suites must not open the same file.
    ///
    /// `gitPath` defaults to a binary that always fails, matching every other
    /// end-to-end stack: `GitClient.porcelainStatus` swallows a failing `git`
    /// into `""`, so a caller that wants the sentinel to say anything real —
    /// rather than compare two swallowed failures and call the coincidence
    /// "clean" — must pass a working `git` and `git init` the fixture repo.
    private func makeStack(
        extraEnv: [String: String] = [:], gitPath: String = "/usr/bin/false"
    ) async throws -> Stack {
        let home = TestHome.scratch("analysis-e2e")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try StoreLocation.ensureDirectories()

        let repoRoot = home.appendingPathComponent("repo", isDirectory: true)
        let sources = repoRoot.appendingPathComponent("Sources/ElliotProcess", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "// real".write(
            to: sources.appendingPathComponent("ClaudeRunner.swift"), atomically: true, encoding: .utf8
        )

        let store = try BoardStore.open(at: home.appendingPathComponent("elliot.sqlite"))
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        environment["FAKE_CLAUDE_FIXTURE"] = TestPaths.streamFixture("analyze-success.ndjson")
        environment["FAKE_CLAUDE_STORIES"] = TestPaths.analysisFixture("e2e-bugs.json")
        environment.merge(extraEnv) { _, new in new }

        let config = ToolConfig(
            claudePath: TestPaths.fakeClaude,
            ghPath: "/usr/bin/false",
            gitPath: gitPath,
            environment: environment
        )
        let scheduler = RunScheduler(
            store: store, toolConfig: config, verifier: Verifier(gh: .init(config: config))
        )
        let board = BoardService(store: store, launcher: scheduler)
        await scheduler.setSystemMover(board)
        let analysisService = AnalysisService(
            store: store, launcher: scheduler, board: board, gh: GHClient(config: config)
        )

        let repo = Repo(
            path: repoRoot.path, nameWithOwner: "phmatray/Elliot", displayName: "Elliot"
        )
        try await store.saveRepo(repo)

        return Stack(
            store: store, board: board, scheduler: scheduler,
            analysisService: analysisService, repo: repo, home: home
        )
    }

    @Test("An analysis produces proposals, and accepting one puts a real card in Backlog")
    func theWholePath() async throws {
        // Real git, when available, so the "clean" assertion below checks an
        // actual `git status` rather than two calls to a failing binary that
        // happen to agree with each other. `/usr/bin/git` ships with the
        // Xcode command-line tools this package itself needs to build, so
        // the fallback is not expected to be exercised in practice.
        let git = "/usr/bin/git"
        let gitAvailable = FileManager.default.isExecutableFile(atPath: git)
        let stack = try await makeStack(gitPath: gitAvailable ? git : "/usr/bin/false")
        defer { stack.cleanUp() }
        if gitAvailable {
            _ = try? await ProcessRunner.run(
                executable: git, arguments: ["init", "-q"], cwd: stack.repo.path,
                environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(20)
            )
        }

        // A card already on the board, so the duplicate hint has something to
        // collide with.
        let existingCard = try await stack.board.createCard(
            repoID: stack.repo.id, title: "Cache the login shell environment"
        )

        let started = try await stack.analysisService.start(
            repoID: stack.repo.id, angles: [.bugs, .quickWins],
            maxStoriesPerAngle: 8, origin: .manual
        )
        #expect(started.runs.count == 2)

        let runs = try await stack.awaitRuns(analysisID: started.analysis.id)
        #expect(runs.count == 2)
        #expect(runs.allSatisfy { $0.state == .succeeded })
        #expect(runs.allSatisfy { $0.exitCode == 0 })

        // Both runs harvested from the artifact, not from prose.
        for run in runs {
            let report = try #require(run.analysisReport)
            #expect(report.harvestSource == .artifact)
            #expect(report.kept == 2)
            // The third story in the fixture is unusable, and says why.
            #expect(report.dropped.contains { $0.contains("benefit") })
            if gitAvailable {
                // Checked-and-clean, not "never checked": a real `git status`
                // was taken before and after, over an actually-initialised
                // repo, and found nothing — `false`, not `nil`. Neither run
                // writes inside the repo (the artifact lands under the
                // shared `TestHome.root`, not `stack.repo.path`), so a
                // regression that made a run touch the repo would flip this.
                #expect(report.workingTreeChanged == false)
            }
        }

        // Two angles × two usable stories.
        let proposals = try await stack.store.proposals(analysisID: started.analysis.id)
        #expect(proposals.count == 4)

        let watchdog = try #require(proposals.first { $0.title.contains("idle watchdog") })
        #expect(watchdog.effort == .small)
        #expect(watchdog.story.acceptanceCriteria.count == 2)
        // The cited file exists in this fixture repo; the other one does not.
        #expect(watchdog.evidence.first?.exists == true)
        #expect(watchdog.isGrounded)
        // Negative control: nothing on the board looks like this one, so the
        // hint must be absent rather than pointing at whatever card happens
        // to be first.
        #expect(watchdog.duplicateOf == nil)

        let cached = try #require(proposals.first { $0.title.contains("Cache the login shell") })
        #expect(cached.evidence.first?.exists == false)
        guard case .card(let duplicateID, let duplicateTitle)? = cached.duplicateOf else {
            Issue.record("expected a duplicate hint against the existing card")
            return
        }
        // Bound, not just matched on shape: this is the seeded card, not
        // some other one a matcher that always returns the same hint would
        // also satisfy.
        #expect(duplicateID == existingCard.id)
        #expect(duplicateTitle == existingCard.displayTitle)

        // Accept one. It lands in Backlog and fires nothing.
        let cards = try await stack.analysisService.accept(proposalIDs: [watchdog.id])
        #expect(cards.count == 1)
        let card = cards[0]
        #expect(card.column == .backlog)
        #expect(try await stack.store.runs(cardID: card.id).isEmpty)

        // And it behaves like any other card: dragging it to To Do runs
        // create-issue, through the same funnel and the same rule engine.
        let result = try await stack.board.move(cardID: card.id, to: .todo, origin: .userDrag)
        guard case .moved(let runID?) = result else {
            Issue.record("expected a run, got \(result)")
            return
        }
        let issueRun = try #require(try await stack.store.run(id: runID))
        #expect(issueRun.kind == .createIssue)
        #expect(issueRun.cardID == card.id)
        #expect(issueRun.prompt.hasPrefix("/ai-migration-kit:create-issue"))
        #expect(issueRun.prompt.contains("the idle task cancelled on every exit path"))
    }

    @Test("An analysis that edits the repository is reported, not hidden")
    func theSentinelFires() async throws {
        // A real git binary is needed for the sentinel to say anything.
        let git = "/usr/bin/git"
        guard FileManager.default.isExecutableFile(atPath: git) else { return }

        let stack = try await makeStack(
            extraEnv: ["FAKE_CLAUDE_TOUCH": "meddled.txt"], gitPath: git
        )
        defer { stack.cleanUp() }

        _ = try? await ProcessRunner.run(
            executable: git, arguments: ["init", "-q"], cwd: stack.repo.path,
            environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(20)
        )

        let started = try await stack.analysisService.start(
            repoID: stack.repo.id, angles: [.bugs], origin: .manual
        )
        let runs = try await stack.awaitRuns(analysisID: started.analysis.id)
        let report = try #require(runs.first?.analysisReport)

        // Elliot cannot stop a run writing to the repo. It notices — checked,
        // and found something, which is `true`, not merely truthy.
        #expect(report.workingTreeChanged == true)
        #expect(report.workingTreeDiff?.contains("meddled.txt") == true)
        // And the proposals are still harvested — the sentinel reports, it does
        // not punish.
        #expect(report.kept == 2)
    }
}

}  // extension EndToEndSuites
