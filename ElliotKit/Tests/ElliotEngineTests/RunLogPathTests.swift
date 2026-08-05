import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine

private actor SilentLauncher: RunLaunching {
    func launch(runID: UUID) async {}
    func cancel(runID: UUID) async {}
}

/// Two processes agree on where a run's log lives by computing the path, never
/// by passing it. `BoardService` writes there and `elliot://run/{id}/log` reads
/// there, and neither ever tells the other.
///
/// Pinned because the coupling is invisible: change the filename in
/// `StoreLocation` and update the writer, and the suite stays green while the
/// resource answers "no log file for run …" for every run that exists — which
/// reads to an agent as "the run produced nothing".
@Suite("Where a run's log goes")
struct RunLogPathTests {

    @Test("The path a run records is the one the resource recomputes")
    func recordedPathIsTheComputedPath() async throws {
        let store = try BoardStore.inMemory()
        let board = BoardService(store: store, launcher: SilentLauncher())
        let repo = Repo(path: "/tmp/elliot", nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        try await store.saveRepo(repo)

        let card = try await board.createCard(
            repoID: repo.id,
            title: "Stream the run log",
            story: UserStory(
                role: "developer",
                want: "to see the run log inside the card",
                benefit: "I can diagnose without a terminal"
            )
        ).card
        guard case .moved(let runID?) = try await board.move(
            cardID: card.id, to: .todo, origin: .userDrag
        ) else {
            Issue.record("backlog → todo should have queued a run")
            return
        }

        let run = try #require(try await store.run(id: runID))
        #expect(run.logPath == StoreLocation.runLogURL(runID: runID).path)
        #expect(run.stderrPath == StoreLocation.runStderrURL(runID: runID).path)
    }
}
