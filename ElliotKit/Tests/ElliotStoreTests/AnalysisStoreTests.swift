import ElliotModel
import Foundation
import GRDB
import Testing

@testable import ElliotStore

@Suite("Analysis store")
struct AnalysisStoreTests {

    private func seededStore() async throws -> (BoardStore, Repo) {
        let store = try BoardStore.inMemory()
        let repo = Repo(path: "/tmp/r", nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        try await store.saveRepo(repo)
        return (store, repo)
    }

    @Test("An analysis and its proposals round-trip")
    func roundTrip() async throws {
        let (store, repo) = try await seededStore()
        let analysis = Analysis(
            repoID: repo.id, angles: [.bugs, .quickWins],
            extraInstructions: "focus on ElliotProcess", maxStoriesPerAngle: 5,
            origin: .mcp(client: "claude-code"), createdAt: Date()
        )
        try await store.saveAnalysis(analysis)

        let loaded = try #require(try await store.analysis(id: analysis.id))
        #expect(loaded.angles == [.bugs, .quickWins])
        #expect(loaded.maxStoriesPerAngle == 5)
        #expect(loaded.origin == .mcp(client: "claude-code"))

        let proposal = StoryProposal(
            analysisID: analysis.id, runID: UUID(), repoID: repo.id, angle: .bugs,
            title: "Idle window leaks on cancellation",
            story: UserStory(role: "developer", want: "the idle task to stop", benefit: "no wakeups"),
            rationale: "The task is only cancelled on the happy path.",
            evidence: [Evidence(path: "Sources/ElliotProcess/ClaudeRunner.swift", line: 159, exists: true)],
            effort: .small,
            duplicateOf: .issue(number: 12, title: "Idle leak"),
            createdAt: Date()
        )
        try await store.saveProposals([proposal])

        let back = try #require(try await store.proposal(id: proposal.id))
        #expect(back.story.narrative.hasPrefix("As a developer"))
        #expect(back.evidence.first?.line == 159)
        #expect(back.duplicateOf == .issue(number: 12, title: "Idle leak"))
        #expect(back.status == .proposed)
    }

    @Test("Proposals filter by analysis and by status")
    func filtering() async throws {
        let (store, repo) = try await seededStore()
        let analysis = Analysis(repoID: repo.id, angles: [.bugs], createdAt: Date())
        try await store.saveAnalysis(analysis)

        func make(_ title: String, _ status: ProposalStatus) -> StoryProposal {
            StoryProposal(
                analysisID: analysis.id, runID: UUID(), repoID: repo.id, angle: .bugs,
                title: title,
                story: UserStory(role: "dev", want: "w", benefit: "b"),
                status: status, createdAt: Date()
            )
        }
        try await store.saveProposals([make("A", .proposed), make("B", .accepted), make("C", .rejected)])

        #expect(try await store.proposals(analysisID: analysis.id).count == 3)
        #expect(try await store.proposals(analysisID: analysis.id, status: .proposed).count == 1)
        #expect(try await store.proposals(repoID: repo.id, status: .accepted).map(\.title) == ["B"])
    }

    @Test("An analysis run stores its angle and no card")
    func analysisRunHasNoCard() async throws {
        let (store, repo) = try await seededStore()
        let analysis = Analysis(repoID: repo.id, angles: [.tests], createdAt: Date())
        try await store.saveAnalysis(analysis)

        let run = SkillRun.analysis(
            repoID: repo.id, analysisID: analysis.id, analysisAngle: .tests,
            prompt: "…", cwd: repo.path,
            logPath: "/tmp/x.ndjson", stderrPath: "/tmp/x.log", createdAt: Date()
        )
        try await store.saveRun(run)

        let back = try #require(try await store.run(id: run.id))
        #expect(back.cardID == nil)
        #expect(back.analysisAngle == .tests)
        #expect(try await store.runs(analysisID: analysis.id).count == 1)
    }

    @Test("The report a run writes about itself survives a round trip")
    func reportRoundTrip() async throws {
        let (store, repo) = try await seededStore()
        let analysis = Analysis(repoID: repo.id, angles: [.bugs], createdAt: Date())
        try await store.saveAnalysis(analysis)

        var run = SkillRun.analysis(
            repoID: repo.id, analysisID: analysis.id, analysisAngle: .bugs,
            prompt: "…", cwd: repo.path,
            logPath: "/tmp/y.ndjson", stderrPath: "/tmp/y.log", createdAt: Date()
        )
        run.analysisReport = AnalysisRunReport(
            harvestSource: .resultText, kept: 3, dropped: ["“X” was dropped: missing benefit."],
            workingTreeChanged: true, workingTreeDiff: " M Sources/A.swift"
        )
        try await store.saveRun(run)

        let back = try #require(try await store.run(id: run.id)?.analysisReport)
        #expect(back.harvestSource == .resultText)
        #expect(back.workingTreeChanged)
        #expect(back.dropped.count == 1)
    }

    @Test("Deleting a repository takes its analyses and proposals with it")
    func cascade() async throws {
        let (store, repo) = try await seededStore()
        let analysis = Analysis(repoID: repo.id, angles: [.bugs], createdAt: Date())
        try await store.saveAnalysis(analysis)
        try await store.saveProposals([StoryProposal(
            analysisID: analysis.id, runID: UUID(), repoID: repo.id, angle: .bugs, title: "A",
            story: UserStory(role: "dev", want: "w", benefit: "b"), createdAt: Date()
        )])

        try await store.deleteRepo(id: repo.id)
        #expect(try await store.analysis(id: analysis.id) == nil)
        #expect(try await store.proposals(analysisID: analysis.id).isEmpty)
    }

    // MARK: - The card/analysis invariant

    /// "Exactly one of cardID and analysisID" was previously three independently
    /// settable facts (`kind`, `analysisID`, `analysisAngle`) with nothing tying
    /// them together. The factories are the obvious, unconstructible-wrong path;
    /// the CHECK constraint below is the backstop for whatever still reaches the
    /// database through the memberwise init.
    @Test("A card run and an analysis run both save")
    func cardAndAnalysisRunsSave() async throws {
        let (store, repo) = try await seededStore()
        let card = Card(repoID: repo.id, title: "T", columnEnteredAt: Date(), createdAt: Date(), updatedAt: Date())
        try await store.saveCard(card)
        let analysis = Analysis(repoID: repo.id, angles: [.bugs], createdAt: Date())
        try await store.saveAnalysis(analysis)

        let cardRun = SkillRun.card(
            cardID: card.id, repoID: repo.id, kind: .createIssue, prompt: "…", cwd: repo.path,
            logPath: "/tmp/c.ndjson", stderrPath: "/tmp/c.log", createdAt: Date()
        )
        try await store.saveRun(cardRun)

        let analysisRun = SkillRun.analysis(
            repoID: repo.id, analysisID: analysis.id, analysisAngle: .bugs, prompt: "…",
            cwd: repo.path, logPath: "/tmp/a.ndjson", stderrPath: "/tmp/a.log", createdAt: Date()
        )
        try await store.saveRun(analysisRun)

        let savedCardRun = try #require(try await store.run(id: cardRun.id))
        #expect(savedCardRun.cardID == card.id)
        #expect(savedCardRun.analysisID == nil)

        let savedAnalysisRun = try #require(try await store.run(id: analysisRun.id))
        #expect(savedAnalysisRun.cardID == nil)
        #expect(savedAnalysisRun.analysisID == analysis.id)
        #expect(savedAnalysisRun.kind == .analyzeRepo)
    }

    @Test("A run with both a card and an analysis is rejected")
    func bothCardAndAnalysisRejected() async throws {
        let (store, repo) = try await seededStore()
        let card = Card(repoID: repo.id, title: "T", columnEnteredAt: Date(), createdAt: Date(), updatedAt: Date())
        try await store.saveCard(card)
        let analysis = Analysis(repoID: repo.id, angles: [.bugs], createdAt: Date())
        try await store.saveAnalysis(analysis)

        // Only reachable through the memberwise init: neither factory can
        // produce this combination.
        let run = SkillRun(
            cardID: card.id, repoID: repo.id, analysisID: analysis.id, analysisAngle: .bugs,
            kind: .analyzeRepo, prompt: "…", cwd: repo.path,
            logPath: "/tmp/both.ndjson", stderrPath: "/tmp/both.log", createdAt: Date()
        )
        await #expect(throws: (any Error).self) {
            try await store.saveRun(run)
        }
    }

    @Test("A run with neither a card nor an analysis is rejected")
    func neitherCardNorAnalysisRejected() async throws {
        let (store, repo) = try await seededStore()

        let run = SkillRun(
            cardID: nil, repoID: repo.id, kind: .createIssue, prompt: "…", cwd: repo.path,
            logPath: "/tmp/neither.ndjson", stderrPath: "/tmp/neither.log", createdAt: Date()
        )
        await #expect(throws: (any Error).self) {
            try await store.saveRun(run)
        }
    }

    /// The migration is the one part of this feature that can lose data.
    ///
    /// Every one of the 19 v1 `skillRun` columns — including the 7 nullable
    /// ones a lighter seed would leave NULL — gets a distinct, non-default
    /// value, and every field on the round-tripped `SkillRun` is asserted.
    /// A same-type transposition in the migration's `INSERT … SELECT` (say
    /// `logPath` ↔ `stderrPath`, both TEXT) changes an assertion below rather
    /// than passing unnoticed: nothing here can move to another column of the
    /// same type without a value no longer matching where it started.
    @Test("Migrating a populated v1 database loses nothing")
    func migrationPreservesRows() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elliot-migration-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        // Build a v1 database by running only the first migration.
        var v1 = DatabaseMigrator()
        v1.registerMigration("v1_initial", migrate: Migrations.v1Initial)
        let pool = try DatabasePool(path: url.path)
        try v1.migrate(pool)

        let repoID = UUID(), cardID = UUID(), runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let endedAt = Date(timeIntervalSince1970: 1_700_000_200)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let argv = try jsonText(["claude", "-p", "distinct-argv"])
        let permissionDenials = try jsonText(["Bash(rm:*)"])
        let verifiedOutcome = try jsonText(
            VerifiedOutcome.issueCreated(number: 99, url: "https://distinct.example/99")
        )

        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO "repo" VALUES (?,?,?,?,?,?,?,1)
                    """,
                arguments: [repoID.databaseKey, "/tmp/r", "phmatray/Elliot", "main",
                            "Elliot", "bypassPermissions", "[]"]
            )
            try db.execute(
                sql: """
                    INSERT INTO "card" ("id","repoID","title","body","column","orderIndex",
                                        "columnEnteredAt","createdAt","updatedAt")
                    VALUES (?,?,?,?,?,?,?,?,?)
                    """,
                arguments: [cardID.databaseKey, repoID.databaseKey, "Dark mode", "",
                            "backlog", 1024.0, Date(), Date(), Date()]
            )
            try db.execute(
                sql: """
                    INSERT INTO "skillRun" (
                      "id","cardID","repoID","kind","prompt","argv","cwd","state",
                      "startedAt","endedAt","exitCode","logPath","stderrPath","resultText",
                      "totalCostUSD","numTurns","permissionDenials","verifiedOutcome","createdAt"
                    )
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """,
                arguments: [
                    runID.databaseKey, cardID.databaseKey, repoID.databaseKey,
                    "createIssue", "/ai-migration-kit:create-issue distinct-prompt", argv,
                    "/tmp/distinct-cwd", "succeeded",
                    startedAt, endedAt, Int32(7),
                    "/tmp/distinct.ndjson", "/tmp/distinct.stderr.log", "distinct result text",
                    1.23, 4, permissionDenials, verifiedOutcome, createdAt,
                ]
            )
        }
        try await pool.close()

        // Now open it the way the app does, which runs every migration.
        let store = try BoardStore.open(at: url)
        #expect(try await store.repo(id: repoID) != nil)
        #expect(try await store.card(id: cardID)?.title == "Dark mode")

        let run = try #require(try await store.run(id: runID))
        #expect(run.id == runID)
        #expect(run.cardID == cardID)
        #expect(run.repoID == repoID)
        #expect(run.kind == .createIssue)
        #expect(run.prompt == "/ai-migration-kit:create-issue distinct-prompt")
        #expect(run.argv == ["claude", "-p", "distinct-argv"])
        #expect(run.cwd == "/tmp/distinct-cwd")
        #expect(run.state == .succeeded)
        #expect(run.startedAt == startedAt)
        #expect(run.endedAt == endedAt)
        #expect(run.exitCode == 7)
        #expect(run.logPath == "/tmp/distinct.ndjson")
        #expect(run.stderrPath == "/tmp/distinct.stderr.log")
        #expect(run.resultText == "distinct result text")
        #expect(run.totalCostUSD == 1.23)
        #expect(run.numTurns == 4)
        #expect(run.permissionDenials == ["Bash(rm:*)"])
        #expect(run.verifiedOutcome == .issueCreated(number: 99, url: "https://distinct.example/99"))
        #expect(run.createdAt == createdAt)
        // The three columns v2 adds are not in the v1 seed, so a clean migration
        // leaves them nil rather than inventing a value.
        #expect(run.analysisID == nil)
        #expect(run.analysisAngle == nil)
        #expect(run.analysisReport == nil)
    }
}

/// Encodes a value exactly as GRDB would before storing it in a TEXT column,
/// so a hand-built v1 row matches what the real app would have written.
private func jsonText(_ value: some Encodable) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
}
