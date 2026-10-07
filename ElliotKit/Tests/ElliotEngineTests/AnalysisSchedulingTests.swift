import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine

@Suite("Analysis scheduling")
struct AnalysisSchedulingTests {

    private func makeScheduler() throws -> (RunScheduler, Repo) {
        let store = try BoardStore.inMemory()
        let config = ToolConfig(
            ghPath: "/usr/bin/false",
            gitPath: "/usr/bin/false", environment: [:]
        )
        let scheduler = RunScheduler(
            store: store, toolConfig: config, verifier: Verifier(gh: .init(config: config))
        )
        let repo = Repo(path: "/tmp/r", nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        return (scheduler, repo)
    }

    private func run(_ kind: SkillKind, repoID: UUID, angle: AnalysisAngle? = nil) -> SkillRun {
        SkillRun(
            cardID: kind == .analyzeRepo ? nil : UUID(),
            repoID: repoID,
            analysisID: kind == .analyzeRepo ? UUID() : nil,
            analysisAngle: angle,
            kind: kind, prompt: "…", cwd: "/tmp/r",
            logPath: "/tmp/a.ndjson", stderrPath: "/tmp/a.log", createdAt: Date()
        )
    }

    @Test("An analysis waits for a merge in the same repo, and nothing else",
          arguments: [
            (SkillKind.mergePR, false), (.implementIssue, true), (.createIssue, true),
            (.analyzeRepo, true), (.appraiseCards, true),
          ])
    func analysisAdmission(inFlight: SkillKind, admitted: Bool) async throws {
        let (scheduler, repo) = try makeScheduler()
        await scheduler.testOnlyMarkInFlight(run(inFlight, repoID: repo.id))
        let candidate = run(.analyzeRepo, repoID: repo.id, angle: .bugs)
        #expect(await scheduler.canStart(candidate) == admitted)
    }

    @Test("An analysis in another repo never blocks anything")
    func otherReposAreIrrelevant() async throws {
        let (scheduler, repo) = try makeScheduler()
        await scheduler.testOnlyMarkInFlight(run(.mergePR, repoID: UUID()))
        #expect(await scheduler.canStart(run(.analyzeRepo, repoID: repo.id, angle: .bugs)))
    }

    /// The cap of 2 exists so two builds do not share one .build/. An analysis
    /// compiles nothing, so it must not consume that budget.
    @Test("Analyses do not compete with the runs that write")
    func analysesHaveTheirOwnLane() async throws {
        let (scheduler, repo) = try makeScheduler()
        await scheduler.testOnlyMarkInFlight(run(.analyzeRepo, repoID: repo.id, angle: .bugs))
        await scheduler.testOnlyMarkInFlight(run(.analyzeRepo, repoID: repo.id, angle: .tests))
        // Two analyses in flight, and an implement-issue can still start.
        #expect(await scheduler.canStart(run(.implementIssue, repoID: repo.id)))
        // A third analysis fits; a fourth does not.
        #expect(await scheduler.canStart(run(.analyzeRepo, repoID: repo.id, angle: .features)))
        await scheduler.testOnlyMarkInFlight(run(.analyzeRepo, repoID: repo.id, angle: .features))
        #expect(await scheduler.canStart(run(.analyzeRepo, repoID: repo.id, angle: .docsAndDX)) == false)
    }

    @Test("A merge still waits for a running analysis, without a new rule")
    func mergeWaitsForAnalysis() async throws {
        let (scheduler, repo) = try makeScheduler()
        await scheduler.testOnlyMarkInFlight(run(.analyzeRepo, repoID: repo.id, angle: .bugs))
        #expect(await scheduler.canStart(run(.mergePR, repoID: repo.id)) == false)
    }
}
