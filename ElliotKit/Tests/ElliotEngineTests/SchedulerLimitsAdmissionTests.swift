import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine

/// The limits were constructor constants nobody ever passed. These cover the
/// half that matters at runtime: that admission reads them, that changing them
/// takes effect immediately, and that lowering one never kills a live run.
///
/// Nothing here spawns a process — `testOnlyMarkInFlight` seeds the in-flight
/// set and `canStart` is asked directly, which is the same thing `pump()` does.
@Suite("Scheduler limits — admission")
struct SchedulerLimitsAdmissionTests {

    private func scheduler(_ limits: SchedulerLimits) throws -> RunScheduler {
        let store = try BoardStore.inMemory()
        let config = ToolConfig(
            claudePath: "/usr/bin/true", ghPath: "/usr/bin/true",
            gitPath: "/usr/bin/true", environment: [:]
        )
        return RunScheduler(
            store: store, toolConfig: config,
            verifier: Verifier(gh: .init(config: config)), limits: limits
        )
    }

    private func run(_ kind: SkillKind, repo: UUID = UUID()) -> SkillRun {
        SkillRun(
            cardID: UUID(), repoID: repo, kind: kind, prompt: "x", cwd: "/tmp",
            logPath: "/tmp/a", stderrPath: "/tmp/b", createdAt: Date()
        )
    }

    @Test("Admission counts against the configured writer cap, not a constant")
    func writerCapIsRead() async throws {
        let scheduler = try scheduler(SchedulerLimits(maxConcurrent: 3, maxConcurrentAnalyses: 3))
        for _ in 0..<3 {
            await scheduler.testOnlyMarkInFlight(run(.implementIssue))
        }
        // Three in flight against a cap of three: full.
        #expect(await scheduler.canStart(run(.implementIssue)) == false)
    }

    @Test("A wider cap admits what a narrower one refused")
    func widerCapAdmits() async throws {
        let scheduler = try scheduler(SchedulerLimits(maxConcurrent: 2, maxConcurrentAnalyses: 3))
        for _ in 0..<2 {
            await scheduler.testOnlyMarkInFlight(run(.implementIssue))
        }
        #expect(await scheduler.canStart(run(.implementIssue)) == false)

        await scheduler.setLimits(SchedulerLimits(maxConcurrent: 4, maxConcurrentAnalyses: 3))
        #expect(await scheduler.canStart(run(.implementIssue)) == true)
    }

    @Test("Analyses have their own lane and do not consume the writer cap")
    func analysesAreCountedSeparately() async throws {
        let scheduler = try scheduler(SchedulerLimits(maxConcurrent: 1, maxConcurrentAnalyses: 3))
        // Two analyses in flight, in different repos so the same-repo merge rule
        // does not decide this instead.
        await scheduler.testOnlyMarkInFlight(run(.analyzeRepo))
        await scheduler.testOnlyMarkInFlight(run(.analyzeRepo))
        // The writer lane is still empty, so a writer is admitted even though
        // two runs are going and the writer cap is one.
        #expect(await scheduler.canStart(run(.implementIssue)) == true)
        #expect(await scheduler.canStart(run(.analyzeRepo)) == true)
    }

    @Test("The analysis cap is read too")
    func analysisCapIsRead() async throws {
        let scheduler = try scheduler(SchedulerLimits(maxConcurrent: 4, maxConcurrentAnalyses: 2))
        await scheduler.testOnlyMarkInFlight(run(.analyzeRepo))
        await scheduler.testOnlyMarkInFlight(run(.analyzeRepo))
        #expect(await scheduler.canStart(run(.analyzeRepo)) == false)
        #expect(await scheduler.canStart(run(.implementIssue)) == true)
    }

    @Test("Lowering the cap below what is in flight kills nothing")
    func loweringDoesNotKill() async throws {
        let scheduler = try scheduler(SchedulerLimits(maxConcurrent: 4, maxConcurrentAnalyses: 3))
        for _ in 0..<3 {
            await scheduler.testOnlyMarkInFlight(run(.implementIssue))
        }
        #expect(await scheduler.activeRunCount == 3)

        await scheduler.setLimits(SchedulerLimits(maxConcurrent: 1, maxConcurrentAnalyses: 1))

        // Still three: `canStart` is only consulted for runs that have not
        // started. The new cap takes effect as they drain, and nothing was
        // cancelled to make the number fit.
        #expect(await scheduler.activeRunCount == 3)
        #expect(await scheduler.canStart(run(.implementIssue)) == false)
    }

    @Test("Occupancy separates writers from analyses")
    func occupancyIsSplit() async throws {
        let scheduler = try scheduler(.default)
        await scheduler.testOnlyMarkInFlight(run(.implementIssue))
        await scheduler.testOnlyMarkInFlight(run(.analyzeRepo))
        await scheduler.testOnlyMarkInFlight(run(.analyzeRepo))

        let occupancy = await scheduler.occupancy
        #expect(occupancy.writers == 1)
        #expect(occupancy.analyses == 2)
    }

    @Test("The scheduler reports the limits it was given")
    func limitsAreReadable() async throws {
        let scheduler = try scheduler(SchedulerLimits(maxConcurrent: 5, maxConcurrentAnalyses: 6))
        #expect(await scheduler.currentLimits == SchedulerLimits(maxConcurrent: 5, maxConcurrentAnalyses: 6))
    }
}
