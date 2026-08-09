import ElliotModel
import Foundation
import Testing

@testable import ElliotStore

/// The splits: by repository, by kind, and per analysis.
///
/// `spend(since:)` itself is covered in `SpendStoreTests`; these are the group-by
/// siblings, which is where a wrong join or a dropped NULL hides.
@Suite("Spend — the splits")
struct SpendAggregateTests {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func store() throws -> BoardStore { try BoardStore.inMemory() }

    private func repo(_ store: BoardStore, _ name: String) async throws -> Repo {
        let repo = Repo(
            path: "/tmp/\(name)", nameWithOwner: "phmatray/\(name)",
            defaultBranch: "main", displayName: name
        )
        try await store.saveRepo(repo)
        return repo
    }

    /// `skillRun.analysisID` is a foreign key onto `analysis`, so an analysis
    /// row has to exist before a run can point at one — the first draft of this
    /// suite passed a bare UUID and SQLite refused it, the same way it refused a
    /// bare `repoID` in `SpendStoreTests`.
    private func analysis(_ store: BoardStore, _ repo: Repo) async throws -> UUID {
        let analysis = Analysis(
            repoID: repo.id, angles: [.bugs, .quickWins], createdAt: now
        )
        try await store.saveAnalysis(analysis)
        return analysis.id
    }

    @discardableResult
    private func run(
        _ store: BoardStore, _ repo: Repo, kind: SkillKind = .implementIssue,
        cost: Double?, endedAt: Date? = nil, analysisID: UUID? = nil
    ) async throws -> SkillRun {
        let card = Card(
            repoID: repo.id, title: "c", columnEnteredAt: now, createdAt: now, updatedAt: now
        )
        try await store.saveCard(card)
        var run = SkillRun(
            cardID: analysisID == nil ? card.id : nil, repoID: repo.id, kind: kind,
            prompt: "x", cwd: "/tmp", logPath: "/tmp/a", stderrPath: "/tmp/b", createdAt: now
        )
        run.analysisID = analysisID
        run.totalCostUSD = cost
        run.endedAt = endedAt ?? now
        run.state = .succeeded
        try await store.saveRun(run)
        return run
    }

    @Test("By repository, biggest spender first")
    func byRepoIsOrdered() async throws {
        let store = try store()
        let cheap = try await repo(store, "Lyrics")
        let costly = try await repo(store, "Elliot")
        try await run(store, cheap, cost: 1)
        try await run(store, costly, cost: 10)
        try await run(store, costly, cost: 5)

        let rows = try await store.spendByRepo(since: now.addingTimeInterval(-60))
        #expect(rows.count == 2)
        #expect(rows[0].repoID == costly.id)
        #expect(rows[0].spend.totalUSD == 15)
        #expect(rows[0].spend.runs == 2)
        #expect(rows[1].repoID == cheap.id)
    }

    @Test("A repository that spent nothing in the period does not appear")
    func byRepoSkipsSilentRepos() async throws {
        // A GROUP BY over the period, not a left join over every repository: a
        // row of $0.00 for a repo nobody touched is noise on a portfolio page.
        let store = try store()
        let active = try await repo(store, "Elliot")
        _ = try await repo(store, "Untouched")
        try await run(store, active, cost: 2)

        let rows = try await store.spendByRepo(since: now.addingTimeInterval(-60))
        #expect(rows.count == 1)
        #expect(rows[0].repoID == active.id)
    }

    @Test("Unknown costs are carried into each group, not flattened to zero")
    func byRepoKeepsUnknowns() async throws {
        let store = try store()
        let repo = try await repo(store, "Elliot")
        try await run(store, repo, cost: 3)
        try await run(store, repo, cost: nil)

        let rows = try await store.spendByRepo(since: now.addingTimeInterval(-60))
        #expect(rows[0].spend.totalUSD == 3)
        #expect(rows[0].spend.unknownCost == 1)
        #expect(!rows[0].spend.isComplete)
    }

    @Test("By kind answers what an analysis costs against filing an issue")
    func byKindSeparates() async throws {
        let store = try store()
        let repo = try await repo(store, "Elliot")
        let analysis = try await analysis(store, repo)
        try await run(store, repo, kind: .createIssue, cost: 0.5)
        try await run(store, repo, kind: .analyzeRepo, cost: 4, analysisID: analysis)
        try await run(store, repo, kind: .analyzeRepo, cost: 6, analysisID: analysis)

        let byKind = try await store.spendByKind(since: now.addingTimeInterval(-60))
        #expect(byKind[.createIssue]?.totalUSD == 0.5)
        #expect(byKind[.analyzeRepo]?.totalUSD == 10)
        #expect(byKind[.analyzeRepo]?.runs == 2)
        // A kind nobody ran is absent rather than zero, for the same reason a
        // silent repository is.
        #expect(byKind[.mergePR] == nil)
    }

    @Test("One analysis is summed across its lenses")
    func perAnalysis() async throws {
        let store = try store()
        let repo = try await repo(store, "Elliot")
        let mine = try await analysis(store, repo)
        let other = try await analysis(store, repo)
        try await run(store, repo, kind: .analyzeRepo, cost: 2, analysisID: mine)
        try await run(store, repo, kind: .analyzeRepo, cost: 3, analysisID: mine)
        try await run(store, repo, kind: .analyzeRepo, cost: 99, analysisID: other)

        let spend = try await store.spend(analysisID: mine)
        #expect(spend.totalUSD == 5)
        #expect(spend.runs == 2)
        #expect(spend.isComplete)
    }

    @Test("An analysis with nothing finished has spent nothing, and knows it")
    func analysisWithNoFinishedRuns() async throws {
        // Not an error and not unknown: no run has ended, so no cost exists yet.
        let store = try store()
        #expect(try await store.spend(analysisID: UUID()) == .nothing)
    }

    /// #308: the two halves a screen shows together are read from one boundary,
    /// so the split adds up to the total beside it.
    @Test("The day's total and its split are one reading, from one boundary")
    func daySpendIsOneReading() async throws {
        let store = try store()
        let repo = try await repo(store, "Elliot")
        let analysis = try await analysis(store, repo)
        try await run(store, repo, kind: .createIssue, cost: 0.5)
        try await run(store, repo, kind: .analyzeRepo, cost: 4, analysisID: analysis)
        try await run(store, repo, kind: .analyzeRepo, cost: 6, analysisID: analysis)

        let since = now.addingTimeInterval(-3_600)
        let day = try await store.daySpend(since: since)

        #expect(day.since == since)
        #expect(day.total.totalUSD == 10.5)
        #expect(day.spend(.createIssue).totalUSD == 0.5)
        #expect(day.spend(.analyzeRepo).totalUSD == 10)
        #expect(day.spend(.mergePR) == .nothing)
        // The whole claim in one line: what the columns say adds up to what the
        // total says, because both were asked the same question.
        #expect(day.byKind.values.reduce(0) { $0 + $1.totalUSD } == day.total.totalUSD)
    }

    /// Why it is two statements and not one `GROUP BY` summed in Swift.
    ///
    /// `spendByKind` drops a row whose `kind` string does not decode — a run
    /// written by a build with a fifth skill, met by this one — and it is right
    /// to: it cannot name a column for it. The **total** must still count that
    /// money, or an older build's spend would vanish from the one figure the
    /// ceiling is enforced against.
    @Test("Money spent on a skill this build cannot name is still in the total")
    func anUnknownKindStillCounts() async throws {
        let store = try store()
        let repo = try await repo(store, "Elliot")
        try await run(store, repo, kind: .createIssue, cost: 1)
        // Written past the type, the way a future build would have written it.
        try await store.testOnlyExecute(
            #"UPDATE "skillRun" SET "kind" = 'summoniseRepo', "totalCostUSD" = 7"#)

        let day = try await store.daySpend(since: now.addingTimeInterval(-3_600))
        #expect(day.total.totalUSD == 7)
        #expect(day.total.runs == 1)
        #expect(day.byKind.isEmpty)
        // So the columns are a floor here, and the total is the bill. Summing
        // the columns instead would have reported nothing at all.
        #expect(day.byKind.values.reduce(0) { $0 + $1.totalUSD } != day.total.totalUSD)
    }

    @Test("The period is respected by every split, not only by the total")
    func periodAppliesToSplits() async throws {
        let store = try store()
        let repo = try await repo(store, "Elliot")
        try await run(store, repo, cost: 99, endedAt: now.addingTimeInterval(-7_200))
        try await run(store, repo, cost: 1)

        let since = now.addingTimeInterval(-3_600)
        #expect(try await store.spendByRepo(since: since)[0].spend.totalUSD == 1)
        #expect(try await store.spendByKind(since: since)[.implementIssue]?.totalUSD == 1)
    }
}
