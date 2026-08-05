import ElliotModel
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine

@Suite("GitHub import service")
struct GitHubImportServiceTests {

    /// Stands in for the real scheduler and records nothing being asked of it —
    /// which is the point of the suite.
    actor RecordingLauncher: RunLaunching {
        private(set) var launched: [UUID] = []
        func launch(runID: UUID) async { launched.append(runID) }
        func cancel(runID: UUID) async {}
    }

    private func fixture() async throws -> (BoardStore, BoardService, RecordingLauncher, Repo) {
        let store = try BoardStore.inMemory()
        let launcher = RecordingLauncher()
        let board = BoardService(store: store, launcher: launcher)
        let repo = Repo(path: "/tmp/elliot", nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        try await store.saveRepo(repo)
        return (store, board, launcher, repo)
    }

    @Test("A card adopted into In Review starts no run")
    func importingNeverStartsARun() async throws {
        let (store, board, launcher, repo) = try await fixture()
        let card = try await board.adoptCard(CardSeed(
            repoID: repo.id, title: "feat(app): the board", body: "",
            column: .inReview, issueNumber: 5, prNumber: 6,
            createdAt: Date(timeIntervalSince1970: 0)))

        #expect(card.column == .inReview)
        #expect(await launcher.launched.isEmpty)
        #expect(try await store.runs(repoID: repo.id).isEmpty)
    }

    @Test("Adopting a forward move records the githubImport origin and fires nothing")
    func systemMoveIsAudited() async throws {
        let (store, board, launcher, repo) = try await fixture()
        let card = try await board.createCard(repoID: repo.id, title: "work", column: .todo).card
        var filed = card
        filed.issueNumber = 11
        try await store.saveCard(filed)

        await board.applySystemMove(cardID: card.id, to: .inProgress, reason: .githubImport)

        let audits = try await store.audits(cardID: card.id)
        #expect(audits.contains { $0.to == .inProgress && $0.origin == .system(reason: .githubImport) })
        #expect(await launcher.launched.isEmpty)
    }

    @Test("adoptCard allocates an order index per column, like createCard")
    func adoptAllocatesOrderIndex() async throws {
        let (_, board, _, repo) = try await fixture()
        let t = Date(timeIntervalSince1970: 0)
        let first = try await board.adoptCard(CardSeed(
            repoID: repo.id, title: "a", body: "", column: .todo, issueNumber: 1, createdAt: t))
        let second = try await board.adoptCard(CardSeed(
            repoID: repo.id, title: "b", body: "", column: .todo, issueNumber: 2, createdAt: t))
        #expect(second.orderIndex > first.orderIndex)
    }
}
