import ElliotModel
import Foundation
import Testing

@testable import ElliotStore

/// One grouped read per figure, never one query per repository — on this
/// portfolio that is the difference between a page load and three hundred.
///
/// The seam worth naming is the absent row: a repository with nothing at all is
/// **not** in the answer, and `RepoBoardDigest` is what turns that into
/// `.empty`. A left join over every registration here would move criterion 3
/// into SQL and leave the digest with nothing to prove.
@Suite("Repo board tallies")
struct RepoBoardTallyStoreTests {

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

    @discardableResult
    private func card(_ store: BoardStore, _ repo: Repo) async throws -> Card {
        let card = Card(
            repoID: repo.id, title: "c", columnEnteredAt: now, createdAt: now, updatedAt: now)
        try await store.saveCard(card)
        return card
    }

    /// A run always hangs off exactly one of a card or an analysis — the schema
    /// has a CHECK saying so — so `card` is required here rather than optional.
    /// The first draft of this suite passed neither and SQLite refused it.
    private func run(
        _ store: BoardStore, _ repo: Repo, card: Card, state: RunState,
        cost: Double? = nil, endedAt: Date? = nil
    ) async throws {
        var run = SkillRun(
            cardID: card.id, repoID: repo.id, kind: .implementIssue,
            prompt: "x", cwd: "/tmp", logPath: "/tmp/a", stderrPath: "/tmp/b", createdAt: now)
        run.state = state
        run.totalCostUSD = cost
        run.endedAt = endedAt
        try await store.saveRun(run)
    }

    /// The other half of that CHECK: a run with no card at all. It is how a
    /// repository comes to have runs and spend without a single card.
    private func analysisRun(
        _ store: BoardStore, _ repo: Repo, state: RunState,
        cost: Double? = nil, endedAt: Date? = nil
    ) async throws {
        let analysis = Analysis(repoID: repo.id, angles: [.bugs], createdAt: now)
        try await store.saveAnalysis(analysis)
        var run = SkillRun(
            cardID: nil, repoID: repo.id, analysisID: analysis.id, kind: .analyzeRepo,
            prompt: "x", cwd: "/tmp", logPath: "/tmp/a", stderrPath: "/tmp/b", createdAt: now)
        run.state = state
        run.totalCostUSD = cost
        run.endedAt = endedAt
        try await store.saveRun(run)
    }

    @Test("Cards and in-flight runs are counted per repository, terminal runs never")
    func countsPerRepo() async throws {
        let store = try store()
        let a = try await repo(store, "Elliot")
        let b = try await repo(store, "Koine")
        _ = try await repo(store, "Untouched")

        let held = try await card(store, a)
        let next = try await card(store, a)
        try await card(store, a)
        try await run(store, a, card: held, state: .running)
        try await run(store, a, card: next, state: .queued)

        let done = try await card(store, b)
        try await card(store, b)
        try await run(store, b, card: done, state: .succeeded, cost: 1, endedAt: now)

        let tallies = try await store.repoBoardTallies(since: now.addingTimeInterval(-60))
        #expect(tallies[a.id]?.cards == 3)
        #expect(tallies[a.id]?.runsInFlight == 2)
        #expect(tallies[b.id]?.cards == 2)
        // The one run repo B has is `.succeeded`, which is not in flight. A
        // terminal run counted here would report every finished repository as
        // busy for ever.
        #expect(tallies[b.id]?.runsInFlight == 0)
    }

    @Test("A repository with nothing at all is absent, not zero")
    func silentRepoIsAbsent() async throws {
        let store = try store()
        let active = try await repo(store, "Elliot")
        let empty = try await repo(store, "Untouched")
        try await card(store, active)

        let tallies = try await store.repoBoardTallies(since: now.addingTimeInterval(-60))
        #expect(tallies[empty.id] == nil)
        #expect(tallies[active.id] != nil)
    }

    @Test("Every state the board calls active is in flight, and every terminal one is not")
    func everyStateIsClassifiedTheWayTheBoardClassifiesIt() async throws {
        // Driven off `RunState.isActive` rather than a list written out here:
        // this is the assertion that `activeStates` is what the count means,
        // and a second copy of "in flight" would be a second answer to it.
        for state in RunState.allCases {
            let store = try store()
            let repo = try await repo(store, "Elliot")
            let card = try await card(store, repo)
            try await run(
                store, repo, card: card, state: state, endedAt: state.isTerminal ? now : nil)
            let tallies = try await store.repoBoardTallies(since: now.addingTimeInterval(-60))
            #expect(tallies[repo.id]?.runsInFlight == (state.isActive ? 1 : 0), "\(state)")
        }
    }

    @Test("Today's spend is the same answer spendByRepo gives for the same window")
    func spendMatchesTheSplitItReuses() async throws {
        let store = try store()
        let repo = try await repo(store, "Elliot")
        let card = try await card(store, repo)
        try await run(store, repo, card: card, state: .succeeded, cost: 3, endedAt: now)
        try await run(store, repo, card: card, state: .failed, cost: nil, endedAt: now)

        let since = now.addingTimeInterval(-60)
        let tallies = try await store.repoBoardTallies(since: since)
        let split = try await store.spendByRepo(since: since)
        #expect(tallies[repo.id]?.spendToday == split.first { $0.repoID == repo.id }?.spend)
        #expect(tallies[repo.id]?.spendToday.totalUSD == 3)
        // The unknown is carried rather than flattened, exactly as `Spend`
        // requires — a run whose cost was never recorded must not read as free.
        #expect(tallies[repo.id]?.spendToday.unknownCost == 1)
    }

    @Test("The window applies to spend, and to spend only")
    func windowAppliesToSpendAlone() async throws {
        // Cards and runs in flight are the board's state *now*; only money has a
        // period. A `since` that swallowed the card count would make the page
        // say "no cards" about a repository that has eleven.
        let store = try store()
        let repo = try await repo(store, "Elliot")
        let card = try await card(store, repo)
        try await run(store, repo, card: card, state: .running)
        try await run(
            store, repo, card: card, state: .succeeded, cost: 99,
            endedAt: now.addingTimeInterval(-7_200))

        let tallies = try await store.repoBoardTallies(since: now.addingTimeInterval(-3_600))
        #expect(tallies[repo.id]?.cards == 1)
        #expect(tallies[repo.id]?.runsInFlight == 1)
        #expect(tallies[repo.id]?.spendToday == .nothing)
    }

    @Test("A repository whose cards are gone but which spent money today still appears")
    func spendOnlyRepoIsKept() async throws {
        // The answer is the union of the three reads, not the card count filtered
        // by the others: forgetting a card deletes it, and money that was spent
        // was still spent.
        let store = try store()
        let repo = try await repo(store, "Elliot")
        try await analysisRun(store, repo, state: .succeeded, cost: 2, endedAt: now)

        let tallies = try await store.repoBoardTallies(since: now.addingTimeInterval(-60))
        #expect(tallies[repo.id]?.cards == 0)
        #expect(tallies[repo.id]?.spendToday.totalUSD == 2)
    }

    @Test("Nothing is carried in from session state — the store cannot know a refresh failed")
    func storeNeverInventsAFailure() async throws {
        let store = try store()
        let repo = try await repo(store, "Elliot")
        try await card(store, repo)

        let tallies = try await store.repoBoardTallies(since: now.addingTimeInterval(-60))
        #expect(tallies[repo.id]?.refreshFailure == nil)
    }
}
