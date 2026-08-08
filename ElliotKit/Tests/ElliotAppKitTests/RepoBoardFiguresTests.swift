import ElliotEngine
import ElliotModel
import ElliotStore
import Foundation
import Testing

@testable import ElliotAppKit

/// #209: the Repositories page said nothing about what is *on* any of the
/// repositories it lists, and — worse — a repository whose cards were stale
/// because `gh` failed an hour ago was rendered as a clean `ok`, while the board
/// was drawing that same failure as a banner.
///
/// The two halves are asserted here rather than one layer down because that is
/// where they meet: `RepoBoardDigest` proves the entitlement rule over a pair of
/// dictionaries, and this proves the dictionaries `AppModel` hands it are the
/// ones the board's banner reads.
@Suite("Repository rows carry board figures")
@MainActor
struct RepoBoardFiguresTests {

    private func repo(_ name: String) -> Repo {
        Repo(path: "/tmp/\(name)", nameWithOwner: "o/\(name)", displayName: name)
    }

    private func row(_ repo: Repo, _ issue: RepoIssue) -> RepoRow {
        RepoRow(
            id: repo.nameWithOwner, nameWithOwner: repo.nameWithOwner, path: repo.path,
            repoID: repo.id, issue: issue, detail: repo.path)
    }

    private func failed(_ name: String, _ message: String) -> ImportSummary {
        var summary = ImportSummary(repoName: name)
        summary.failure = message
        return summary
    }

    private func succeeded(_ name: String) -> ImportSummary {
        var summary = ImportSummary(repoName: name)
        summary.created = 3
        return summary
    }

    @Test("A driven row carries its figures; an out-of-scope one carries none")
    func figuresReachOnlyDrivenRows() {
        let model = AppModel()
        let driven = repo("Elliot")
        let fork = repo("Yendor")
        model.testOnlySeed(repos: [driven, fork], cards: [])
        model.testOnlySeedRepoBoard(
            rows: [row(driven, .ok), row(fork, .outOfScope(.fork))],
            tallies: [
                driven.id: RepoBoardTally(cards: 11, runsInFlight: 2, spendToday: .nothing),
                // Present in the dictionary and still dropped: a registered fork
                // has a `repoID`, so "has an id" is the wrong predicate.
                fork.id: RepoBoardTally(cards: 4, runsInFlight: 0, spendToday: .nothing),
            ])

        let rows = model.repoBoardRows
        #expect(rows[0].board?.cards == 11)
        #expect(rows[0].board?.runsInFlight == 2)
        #expect(rows[1].board == nil)
    }

    @Test("A registered repository the store never mentioned says none, not nothing")
    func drivenRowWithNoCards() {
        let model = AppModel()
        let quiet = repo("Untouched")
        model.testOnlySeed(repos: [quiet], cards: [])
        model.testOnlySeedRepoBoard(rows: [row(quiet, .ok)])
        #expect(model.repoBoardRows[0].board == .empty)
    }

    /// Criterion 2, and the whole reason the join happens on read: the row and
    /// the board's banner must be quoting the same string, not two copies of it.
    @Test("A failed refresh reaches the row as the very words the banner shows")
    func failureMatchesTheBanner() {
        let model = AppModel()
        let broken = repo("Elliot")
        model.testOnlySeed(repos: [broken], cards: [])
        model.testOnlySeedRepoBoard(rows: [row(broken, .ok)])
        model.record(failed("Elliot", "gh exited 1: API rate limit exceeded"), for: broken.id)

        let banner = model.visibleImportFailures.first { $0.repo.id == broken.id }?.message
        #expect(banner == "gh exited 1: API rate limit exceeded")
        #expect(model.repoBoardRows[0].board?.refreshFailure == banner)
    }

    @Test("A failure for a repository with nothing on its board still reaches its row")
    func failureWithoutFigures() {
        // `no cards` beside "could not be refreshed" is not a contradiction; it
        // is the two facts the page owes the reader.
        let model = AppModel()
        let broken = repo("Elliot")
        model.testOnlySeed(repos: [broken], cards: [])
        model.testOnlySeedRepoBoard(rows: [row(broken, .ok)])
        model.record(failed("Elliot", "no network"), for: broken.id)

        #expect(model.repoBoardRows[0].board?.cards == 0)
        #expect(model.repoBoardRows[0].board?.refreshFailure == "no network")
    }

    @Test("A later success clears the mark and the banner together")
    func successClearsBoth() {
        let model = AppModel()
        let repo = repo("Elliot")
        model.testOnlySeed(repos: [repo], cards: [])
        model.testOnlySeedRepoBoard(
            rows: [row(repo, .ok)],
            tallies: [repo.id: RepoBoardTally(cards: 3, runsInFlight: 0, spendToday: .nothing)])
        model.record(failed("Elliot", "no network"), for: repo.id)
        #expect(model.repoBoardRows[0].board?.refreshFailure == "no network")

        model.record(succeeded("Elliot"), for: repo.id)
        #expect(model.visibleImportFailures.isEmpty)
        #expect(model.repoBoardRows[0].board?.refreshFailure == nil)
        // The figures are untouched by either: they came from the store.
        #expect(model.repoBoardRows[0].board?.cards == 3)
    }

    @Test("An unregistered row shows nothing, so blank never means zero")
    func unregisteredRowShowsNothing() {
        let model = AppModel()
        model.testOnlySeed(repos: [], cards: [])
        model.testOnlySeedRepoBoard(
            rows: [
                RepoRow(
                    id: "o/Ducky", nameWithOwner: "o/Ducky", path: "/tmp/Ducky",
                    issue: .notRegistered, fixes: [.register(path: "/tmp/Ducky")])
            ])
        #expect(model.repoBoardRows[0].board == nil)
        // And it keeps the one button its verdict allows.
        #expect(model.repoBoardRows[0].fixes.count == 1)
    }

    @Test("Refreshing the figures re-reads the store and nothing else")
    func refreshReadsTheStore() async throws {
        let model = AppModel()
        let store = try BoardStore.inMemory()
        let repo = repo("Elliot")
        try await store.saveRepo(repo)
        let now = Date()
        for _ in 0..<3 {
            try await store.saveCard(
                Card(
                    repoID: repo.id, title: "c", columnEnteredAt: now, createdAt: now,
                    updatedAt: now))
        }
        model.testOnlySeed(repos: [repo], cards: [])
        model.testOnlySeedRepoBoard(rows: [row(repo, .ok)])
        #expect(model.repoBoardRows[0].board == .empty)

        model.testOnlySeedStore(store)
        await model.refreshRepoTallies()
        #expect(model.repoTallies[repo.id]?.cards == 3)
        #expect(model.repoBoardRows[0].board?.cards == 3)
        // It touched only the figures — the rows it was given are the rows it
        // still has, and no `gh repo list` was involved to change them.
        #expect(model.repoRows.count == 1)
        #expect(model.repoRows[0].issue == .ok)
    }

    @Test("With no store behind the model the figures are empty, not stale")
    func noStoreMeansNoFigures() async {
        let model = AppModel()
        let repo = repo("Elliot")
        model.testOnlySeed(repos: [repo], cards: [])
        model.testOnlySeedRepoBoard(
            rows: [row(repo, .ok)],
            tallies: [repo.id: RepoBoardTally(cards: 9, runsInFlight: 1, spendToday: .nothing)])

        await model.refreshRepoTallies()
        #expect(model.repoTallies.isEmpty)
        #expect(model.repoBoardRows[0].board == .empty)
    }
}
