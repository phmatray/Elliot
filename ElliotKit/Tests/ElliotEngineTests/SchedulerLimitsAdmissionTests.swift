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
/// set and `canStart` is asked directly.
///
/// ⚠️ **This line used to end "…which is the same thing `pump()` does", and that
/// stopped being true the day the merge-verdict guard landed.** `canStart` was
/// `refusal(for: run, overBudget: false, mergeVerdict: .notDemanded)` — both
/// permissive values hardcoded — so it answered `true` for a demanding merge on
/// a reading `pump()` refuses, under a sentence in this very file asserting the
/// two agreed. It derives both inputs now, from the ceiling and the run's own
/// `PRStatus`, so the claim holds again; `canStartRefusesWhatPumpRefuses` below
/// is what keeps it holding. The rule the episode leaves behind is narrower than
/// "keep docs current": **a convenience that claims to agree with a decision
/// elsewhere must derive that decision, not restate a safe answer to it.**
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

/// `canStart` used to return a bare `Bool`. These cover the reason it now keeps
/// — the half that turns a queue that has stopped moving from a mystery into a
/// sentence.
@Suite("Queue refusal — which rule is holding a run")
struct QueueRefusalAdmissionTests {

    private func scheduler(_ limits: SchedulerLimits = .default) throws -> RunScheduler {
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

    @Test("An admissible run has no reason not to start")
    func admissibleHasNoRefusal() async throws {
        let scheduler = try scheduler()
        #expect(
            await scheduler.refusal(for: run(.implementIssue), overBudget: false, mergeVerdict: .notDemanded)
                == nil
        )
    }

    @Test("A merge in the repository is named as such, not as a full cap")
    func mergeInRepoIsNamed() async throws {
        let scheduler = try scheduler(SchedulerLimits(maxConcurrent: 8, maxConcurrentAnalyses: 8))
        let repo = UUID()
        await scheduler.testOnlyMarkInFlight(run(.mergePR, repo: repo))
        // Caps are wide open, so if this said "cap reached" it would be sending
        // the user to raise a limit that is not the problem.
        #expect(
            await scheduler.refusal(
                for: run(.implementIssue, repo: repo), overBudget: false, mergeVerdict: .notDemanded
            )
                == .mergeInFlightInRepo
        )
    }

    @Test("The writer cap reports the numbers it is enforcing")
    func writerCapCarriesNumbers() async throws {
        let scheduler = try scheduler(SchedulerLimits(maxConcurrent: 2, maxConcurrentAnalyses: 3))
        await scheduler.testOnlyMarkInFlight(run(.implementIssue))
        await scheduler.testOnlyMarkInFlight(run(.implementIssue))
        #expect(
            await scheduler.refusal(for: run(.implementIssue), overBudget: false, mergeVerdict: .notDemanded)
                == .writerCapReached(inFlight: 2, cap: 2)
        )
    }

    @Test("The analysis cap is reported separately from the writer cap")
    func analysisCapIsItsOwnReason() async throws {
        let scheduler = try scheduler(SchedulerLimits(maxConcurrent: 4, maxConcurrentAnalyses: 1))
        await scheduler.testOnlyMarkInFlight(run(.analyzeRepo))
        #expect(
            await scheduler.refusal(for: run(.analyzeRepo), overBudget: false, mergeVerdict: .notDemanded)
                == .analysisCapReached(inFlight: 1, cap: 1)
        )
        // And a writer is still admissible: the lanes are separate.
        #expect(
            await scheduler.refusal(for: run(.implementIssue), overBudget: false, mergeVerdict: .notDemanded)
                == nil
        )
    }

    @Test("A second create-issue in one repository is named for what it is")
    func duplicateCreateIssue() async throws {
        let scheduler = try scheduler(SchedulerLimits(maxConcurrent: 8, maxConcurrentAnalyses: 8))
        let repo = UUID()
        await scheduler.testOnlyMarkInFlight(run(.createIssue, repo: repo))
        #expect(
            await scheduler.refusal(
                for: run(.createIssue, repo: repo), overBudget: false, mergeVerdict: .notDemanded
            )
                == .duplicateCreateIssueInRepo
        )
        // Only in the same repository — elsewhere it is free to run.
        #expect(
            await scheduler.refusal(for: run(.createIssue), overBudget: false, mergeVerdict: .notDemanded)
                == nil
        )
    }

    @Test("A merge waiting on an analysis says so, rather than blaming a cap")
    func mergeWaitsForIdle() async throws {
        let scheduler = try scheduler(SchedulerLimits(maxConcurrent: 8, maxConcurrentAnalyses: 8))
        let repo = UUID()
        await scheduler.testOnlyMarkInFlight(run(.analyzeRepo, repo: repo))
        #expect(
            await scheduler.refusal(
                for: run(.mergePR, repo: repo), overBudget: false, mergeVerdict: .notDemanded
            )
                == .mergeWaitsForRepoToBeIdle
        )
    }

    @Test("Over budget outranks every other reason")
    func budgetOutranks() async throws {
        // Ordering matters: telling someone to raise the writer cap when the
        // real block is the day's ceiling sends them to fix the wrong thing.
        let scheduler = try scheduler(SchedulerLimits(maxConcurrent: 1, maxConcurrentAnalyses: 1))
        await scheduler.testOnlyMarkInFlight(run(.implementIssue))
        #expect(
            await scheduler.refusal(for: run(.implementIssue), overBudget: true, mergeVerdict: .notDemanded)
                == .dailyCeilingReached
        )
    }

    @Test("canStart still answers the same question, so old callers are unchanged")
    func boolShimAgrees() async throws {
        let scheduler = try scheduler(SchedulerLimits(maxConcurrent: 1, maxConcurrentAnalyses: 1))
        #expect(await scheduler.canStart(run(.implementIssue)) == true)
        await scheduler.testOnlyMarkInFlight(run(.implementIssue))
        #expect(await scheduler.canStart(run(.implementIssue)) == false)
    }

    /// The measurement that opened this finding, turned into a gate: one
    /// scheduler, one store, two merge runs a single flag apart, judged against
    /// a reading 660 seconds old.
    ///
    /// With `.notDemanded` hardcoded inside `canStart`, the demanding half
    /// answered **`true`** while a real `pump()` left that same run `.queued`
    /// under `.mergeVerdictNotEstablished` — a convenience disagreeing with the
    /// decision it advertises agreement with, on the one path that merges to a
    /// default branch on github.com.
    ///
    /// The non-demanding half is not padding: it is what makes the assertion
    /// about *what the move demanded* rather than about the row being old. Both
    /// runs see the same stale `PRStatus`; only one of them asked for a green.
    @Test("canStart refuses a demanding merge on a stale reading, exactly as pump does")
    func canStartRefusesWhatPumpRefuses() async throws {
        let store = try BoardStore.inMemory()
        let config = ToolConfig(
            claudePath: "/usr/bin/true", ghPath: "/usr/bin/true",
            gitPath: "/usr/bin/true", environment: [:]
        )
        let scheduler = RunScheduler(
            store: store, toolConfig: config, verifier: Verifier(gh: .init(config: config)))

        let repo = Repo(
            path: "/tmp/repo-\(UUID().uuidString)", nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot")
        try await store.saveRepo(repo)
        let now = Date()
        let card = Card(
            repoID: repo.id, title: "Landing", column: .done, orderIndex: 0,
            issueNumber: 7, prNumber: 52, branch: "feat/7-landing",
            columnEnteredAt: now, createdAt: now, updatedAt: now)
        try await store.saveCard(card)
        try await store.savePRStatus(
            PRStatus(
                repoID: repo.id, prNumber: 52, headRefOid: "a1b2c3",
                // Dated rather than slept for: no assertion here may measure an
                // absolute duration.
                checkedAt: now.addingTimeInterval(-(PRStatus.maximumAge + 60)),
                rawMergeStateStatus: "CLEAN", rawMergeable: "MERGEABLE",
                rawReviewDecision: "", checks: []))

        func merge(demanding: Bool) -> SkillRun {
            SkillRun.card(
                cardID: card.id, repoID: repo.id, kind: .mergePR, prompt: "x", cwd: "/tmp",
                logPath: "/tmp/a", stderrPath: "/tmp/b",
                requiresVerifiedGreen: demanding ? true : nil, createdAt: now)
        }

        #expect(await scheduler.canStart(merge(demanding: false)) == true)
        #expect(await scheduler.canStart(merge(demanding: true)) == false)
    }
}

/// The daily ceiling, at the one place it acts: admission.
@Suite("Spend ceiling — admission")
struct SpendCeilingAdmissionTests {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    /// A store holding one finished run that cost `spent`, dated today so the
    /// scheduler's start-of-day window includes it.
    private func scheduler(ceiling: SpendCeiling, spentToday: Double?) async throws -> RunScheduler {
        let store = try BoardStore.inMemory()
        let config = ToolConfig(
            claudePath: "/usr/bin/true", ghPath: "/usr/bin/true",
            gitPath: "/usr/bin/true", environment: [:]
        )
        if let spentToday {
            let repo = Repo(
                path: "/tmp/Elliot", nameWithOwner: "phmatray/Elliot",
                defaultBranch: "main", displayName: "Elliot"
            )
            let card = Card(
                repoID: repo.id, title: "spent",
                columnEnteredAt: now, createdAt: now, updatedAt: now
            )
            try await store.saveRepo(repo)
            try await store.saveCard(card)
            var run = SkillRun(
                cardID: card.id, repoID: repo.id, kind: .implementIssue, prompt: "x",
                cwd: "/tmp", logPath: "/tmp/a", stderrPath: "/tmp/b", createdAt: Date()
            )
            run.totalCostUSD = spentToday
            // Dated now, not `self.now`: the scheduler asks for spend since the
            // start of *today*, and a fixed epoch would fall outside it.
            run.endedAt = Date()
            run.state = .succeeded
            try await store.saveRun(run)
        }
        return RunScheduler(
            store: store, toolConfig: config,
            verifier: Verifier(gh: .init(config: config)), ceiling: ceiling
        )
    }

    @Test("No ceiling never refuses, whatever has been spent")
    func offNeverRefuses() async throws {
        let scheduler = try await scheduler(ceiling: .off, spentToday: 10_000)
        #expect(await scheduler.isOverDailyCeiling() == false)
    }

    @Test("Under the ceiling, admission is open")
    func underTheCeiling() async throws {
        let scheduler = try await scheduler(
            ceiling: SpendCeiling(perRunUSD: nil, perDayUSD: 10), spentToday: 4
        )
        #expect(await scheduler.isOverDailyCeiling() == false)
    }

    @Test("At the ceiling, admission closes")
    func atTheCeiling() async throws {
        let scheduler = try await scheduler(
            ceiling: SpendCeiling(perRunUSD: nil, perDayUSD: 10), spentToday: 10
        )
        #expect(await scheduler.isOverDailyCeiling() == true)
    }

    @Test("Raising the ceiling reopens admission immediately")
    func raisingReopens() async throws {
        // The counterpart of `setLimits` calling `pump()`. A ceiling that only
        // took effect at the next finished run would look ignored.
        let scheduler = try await scheduler(
            ceiling: SpendCeiling(perRunUSD: nil, perDayUSD: 5), spentToday: 6
        )
        #expect(await scheduler.isOverDailyCeiling() == true)

        await scheduler.setCeiling(SpendCeiling(perRunUSD: nil, perDayUSD: 50))
        #expect(await scheduler.isOverDailyCeiling() == false)
    }

    @Test("A per-run ceiling alone never closes admission")
    func perRunDoesNotGateAdmission() async throws {
        // The two halves are enforced in different places: the per-run ceiling
        // is Claude Code's job via `--max-budget-usd`, and gating admission on
        // it would refuse runs that have not spent anything yet.
        let scheduler = try await scheduler(
            ceiling: SpendCeiling(perRunUSD: 0.5, perDayUSD: nil), spentToday: 900
        )
        #expect(await scheduler.isOverDailyCeiling() == false)
        #expect(await scheduler.currentCeiling.perRunUSD == 0.5)
    }
}
