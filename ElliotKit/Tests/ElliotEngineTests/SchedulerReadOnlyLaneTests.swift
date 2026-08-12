import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine

/// The witness `SchedulerLimitsAdmissionTests` does not have.
///
/// `refusal(for:)` counts the writer lane with `filter { !$0.kind.isReadOnly }`
/// — a **negation**, which the compiler does not check. Inverted, every
/// appraisal would consume the writer cap that exists to keep two builds out of
/// one `.build/`, and every writer would be admitted without one. Both halves
/// are asserted here, so the inversion cannot ship green.
///
/// Nothing spawns: `testOnlyMarkInFlight` seeds the in-flight set and
/// `refusal(for:overBudget:mergeVerdict:)` is asked directly, which is what
/// `pump()` does. Every call here passes `.notDemanded`: none of these runs
/// asked for a verified green, so admission is exactly what it always was.
@Suite("Scheduler — the read-only lane")
struct SchedulerReadOnlyLaneTests {

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

    /// Distinct repositories by default, so the same-repo merge rule never
    /// decides a case this suite means to be about the caps.
    private func run(_ kind: SkillKind, repo: UUID = UUID()) -> SkillRun {
        SkillRun(
            cardID: kind == .analyzeRepo ? nil : UUID(),
            repoID: repo,
            analysisID: kind == .analyzeRepo ? UUID() : nil,
            kind: kind, prompt: "x", cwd: "/tmp",
            logPath: "/tmp/a", stderrPath: "/tmp/b", createdAt: Date()
        )
    }

    @Test("An appraisal starts even when the writer cap is full")
    func appraisalIgnoresTheWriterCap() async throws {
        let scheduler = try scheduler(SchedulerLimits(maxConcurrent: 2, maxConcurrentAnalyses: 3))
        await scheduler.testOnlyMarkInFlight(run(.implementIssue))
        await scheduler.testOnlyMarkInFlight(run(.createIssue))
        // The writer lane is full — proved, not assumed.
        #expect(
            await scheduler.refusal(for: run(.implementIssue), overBudget: false, mergeVerdict: .notDemanded)
                == .writerCapReached(inFlight: 2, cap: 2)
        )
        // And the appraisal is admitted anyway, because it is not a writer.
        #expect(
            await scheduler.refusal(for: run(.appraiseCards), overBudget: false, mergeVerdict: .notDemanded)
                == nil
        )
    }

    @Test("An appraisal is held by the analysis cap, and says which cap")
    func appraisalCountsAgainstTheAnalysisCap() async throws {
        let scheduler = try scheduler(SchedulerLimits(maxConcurrent: 4, maxConcurrentAnalyses: 2))
        await scheduler.testOnlyMarkInFlight(run(.analyzeRepo))
        await scheduler.testOnlyMarkInFlight(run(.appraiseCards))
        #expect(
            await scheduler.refusal(for: run(.appraiseCards), overBudget: false, mergeVerdict: .notDemanded)
                == .analysisCapReached(inFlight: 2, cap: 2)
        )
        // Naming the right cap matters: "writer cap reached" here would send the
        // reader to raise a limit that is not the block.
        #expect(
            await scheduler.refusal(for: run(.implementIssue), overBudget: false, mergeVerdict: .notDemanded)
                == nil
        )
    }

    @Test("Two appraisals in flight do not make a writer look capped")
    func appraisalsDoNotConsumeTheWriterCap() async throws {
        let scheduler = try scheduler(SchedulerLimits(maxConcurrent: 1, maxConcurrentAnalyses: 3))
        await scheduler.testOnlyMarkInFlight(run(.appraiseCards))
        await scheduler.testOnlyMarkInFlight(run(.appraiseCards))
        #expect(
            await scheduler.refusal(for: run(.implementIssue), overBudget: false, mergeVerdict: .notDemanded)
                == nil
        )
    }

    @Test("Occupancy counts an appraisal on the reading side")
    func occupancySeparatesReadersFromWriters() async throws {
        let scheduler = try scheduler(.default)
        await scheduler.testOnlyMarkInFlight(run(.implementIssue))
        await scheduler.testOnlyMarkInFlight(run(.analyzeRepo))
        await scheduler.testOnlyMarkInFlight(run(.appraiseCards))
        let occupancy = await scheduler.occupancy
        #expect(occupancy.writers == 1)
        #expect(occupancy.analyses == 2)
    }

    @Test("A merge still waits for an appraisal in the same repository")
    func mergeWaitsForAnAppraisal() async throws {
        // `.mergePR` waits for the repository to be idle, and an appraisal reads
        // the working tree — the same reason an analysis makes it wait.
        let scheduler = try scheduler(SchedulerLimits(maxConcurrent: 8, maxConcurrentAnalyses: 8))
        let repo = UUID()
        await scheduler.testOnlyMarkInFlight(run(.appraiseCards, repo: repo))
        #expect(
            await scheduler.refusal(
                for: run(.mergePR, repo: repo), overBudget: false, mergeVerdict: .notDemanded
            )
                == .mergeWaitsForRepoToBeIdle
        )
    }

    @Test("An appraisal waits for a merge in the same repository")
    func appraisalWaitsForAMerge() async throws {
        let scheduler = try scheduler(SchedulerLimits(maxConcurrent: 8, maxConcurrentAnalyses: 8))
        let repo = UUID()
        await scheduler.testOnlyMarkInFlight(run(.mergePR, repo: repo))
        #expect(
            await scheduler.refusal(
                for: run(.appraiseCards, repo: repo), overBudget: false, mergeVerdict: .notDemanded
            )
                == .mergeInFlightInRepo
        )
    }
}
