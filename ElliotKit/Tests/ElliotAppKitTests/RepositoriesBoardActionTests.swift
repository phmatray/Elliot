import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// #143: the Repositories page is the screen that answers *which* repository
/// wants attention, and it could not answer the next question — the only way to
/// its cards was the board's toolbar picker, an unordered list of last path
/// components in which two owners' `Elliot` read alike.
///
/// The dispatch half is asserted here. The decision half — whether a row has the
/// action at all — is `RepoRowBoardAction` in `ElliotModel`, pinned by
/// `RepoRowBoardActionTests`; nothing in this suite re-derives it.
@Suite("Opening the board from a repository row")
@MainActor
struct RepositoriesBoardActionTests {

    private func repo(_ name: String) -> Repo {
        Repo(path: "/tmp/\(name)", nameWithOwner: "o/\(name)", displayName: name)
    }

    private func row(_ repo: Repo, _ issue: RepoIssue = .ok) -> RepoRow {
        RepoRow(
            id: repo.nameWithOwner, nameWithOwner: repo.nameWithOwner, path: repo.path,
            repoID: repo.id, issue: issue, detail: repo.path)
    }

    // MARK: - showBoard

    @Test("Showing the board for a known repository selects it and says so")
    func showBoardSelects() {
        let model = AppModel()
        let elliot = repo("Elliot")
        let koine = repo("Koine")
        model.testOnlySeed(repos: [elliot, koine], cards: [])

        #expect(model.showBoard(repoID: koine.id))
        #expect(model.selectedRepoID == koine.id)
    }

    /// The `forget`-between-sweeps case, and the reason the guard is a guard
    /// rather than a plain assignment: `repoRows` is a snapshot, so a row can
    /// name a registration that no longer exists. What matters is the second
    /// assertion — the selection is left **as it was**, not cleared. Nil'ing it
    /// would answer a click on a stale row by dumping the reader onto the whole
    /// portfolio, silently, which is worse than doing nothing.
    @Test("Showing the board for a forgotten repository changes nothing and says so")
    func showBoardRefusesAnUnknownRepository() {
        let model = AppModel()
        let elliot = repo("Elliot")
        model.testOnlySeed(repos: [elliot], cards: [])
        model.selectedRepoID = elliot.id

        #expect(model.showBoard(repoID: UUID()) == false)
        #expect(model.selectedRepoID == elliot.id, "a refused hop must not clear the current scope")
    }

    // MARK: - selectedRowBoardAction

    @Test("With no row selected there is nothing to open")
    func noSelectionIsUnavailable() {
        let model = AppModel()
        model.testOnlySeedRepoBoard(rows: [row(repo("Elliot"))])

        #expect(model.selectedRepoRowID == nil)
        #expect(model.selectedRowBoardAction == .unavailable)
    }

    /// A selection is a `String` id into a list that is rebuilt by every sweep,
    /// so it can outlive its row. The menu item asks this property whether to be
    /// enabled, so the stale case has to answer `.unavailable` rather than trap.
    @Test("A selection naming no row is unavailable, not a crash")
    func staleSelectionIsUnavailable() {
        let model = AppModel()
        model.testOnlySeedRepoBoard(rows: [row(repo("Elliot"))])
        model.selectedRepoRowID = "o/RepositoryThatWasForgotten"

        #expect(model.selectedRowBoardAction == .unavailable)
    }

    @Test("A selected registered row carries the open action, with its registration")
    func selectedRegisteredRowOpens() {
        let model = AppModel()
        let elliot = repo("Elliot")
        let koine = repo("Koine")
        model.testOnlySeedRepoBoard(rows: [row(elliot), row(koine)])
        model.selectedRepoRowID = koine.nameWithOwner

        #expect(model.selectedRowBoardAction == .open(repoID: koine.id))
    }

    /// The enablement and the action must ask **one** question, so the property
    /// has to keep reporting the row's own verdict rather than "something is
    /// selected". A `.notRegistered` row is selectable like any other.
    @Test("A selected unregistered row asks to be registered first")
    func selectedUnregisteredRowAsksToRegister() {
        let model = AppModel()
        model.testOnlySeedRepoBoard(rows: [
            RepoRow(
                id: "o/Fresh", nameWithOwner: "o/Fresh", path: "/tmp/Fresh",
                issue: .notRegistered, detail: "/tmp/Fresh",
                fixes: [.register(path: "/tmp/Fresh")])
        ])
        model.selectedRepoRowID = "o/Fresh"

        #expect(model.selectedRowBoardAction == .registerFirst)
    }
}
