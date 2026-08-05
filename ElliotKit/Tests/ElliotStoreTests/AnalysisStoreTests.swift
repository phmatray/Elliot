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

        let run = SkillRun(
            cardID: nil, repoID: repo.id, analysisID: analysis.id, analysisAngle: .tests,
            kind: .analyzeRepo, prompt: "…", cwd: repo.path,
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

        var run = SkillRun(
            cardID: nil, repoID: repo.id, analysisID: analysis.id, analysisAngle: .bugs,
            kind: .analyzeRepo, prompt: "…", cwd: repo.path,
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

    /// The migration is the one part of this feature that can lose data.
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
                    INSERT INTO "skillRun" ("id","cardID","repoID","kind","prompt","argv","cwd",
                                            "state","logPath","stderrPath","permissionDenials","createdAt")
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                    """,
                arguments: [runID.databaseKey, cardID.databaseKey, repoID.databaseKey,
                            "createIssue", "/ai-migration-kit:create-issue x", "[]", "/tmp/r",
                            "succeeded", "/tmp/a.ndjson", "/tmp/a.log", "[]", Date()]
            )
        }
        try await pool.close()

        // Now open it the way the app does, which runs every migration.
        let store = try BoardStore.open(at: url)
        #expect(try await store.repo(id: repoID) != nil)
        #expect(try await store.card(id: cardID)?.title == "Dark mode")
        let run = try #require(try await store.run(id: runID))
        #expect(run.cardID == cardID)
        #expect(run.kind == .createIssue)
        #expect(run.analysisID == nil)
    }
}
