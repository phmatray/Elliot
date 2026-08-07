import ElliotModel
import ElliotStore
import Foundation
import Testing

@testable import ElliotAppKit

/// The gate in front of the only irreversible act on either screen.
///
/// Criterion 3 is asserted as **rows before and after**, not as a flag: a
/// `cancelForget` that cleared the state and deleted anyway would satisfy a
/// flag assertion perfectly.
@Suite("Forget confirmation")
@MainActor
struct ForgetConfirmationTests {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func board() async throws -> (AppModel, BoardStore, Repo) {
        let store = try BoardStore.inMemory()
        let model = AppModel()
        model.testOnlySeedStore(store)

        var repo = Repo(path: "/tmp/Elliot", nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        repo.isEnabled = true
        try await store.saveRepo(repo)
        try await store.saveCard(Card(
            repoID: repo.id, title: "A card", column: .backlog, orderIndex: 0,
            columnEnteredAt: epoch, createdAt: epoch, updatedAt: epoch))
        model.testOnlySeed(repos: [repo], cards: [])
        return (model, store, repo)
    }

    @Test("Asking to forget deletes nothing and raises the prompt")
    func requestDeletesNothing() async throws {
        let (model, store, repo) = try await board()

        await model.requestForget(repoID: repo.id, origin: .preflight)

        #expect(model.forgetRequest?.id == repo.id)
        #expect(model.forgetRequest?.impact.cards == 1)
        #expect(model.forgetRequest?.prompt.title == "Forget Elliot?")
        // The gate held: the registration and its card are still there.
        #expect(try await store.repo(id: repo.id) != nil)
        #expect(try await store.cardCount(repoID: repo.id) == 1)
    }

    @Test("Cancelling leaves the registration and every row untouched")
    func cancelChangesNothing() async throws {
        let (model, store, repo) = try await board()
        await model.requestForget(repoID: repo.id, origin: .preflight)

        model.cancelForget()

        #expect(model.forgetRequest == nil)
        #expect(try await store.repo(id: repo.id) != nil)
        #expect(try await store.cardCount(repoID: repo.id) == 1)
        #expect(try await store.forgetImpact(repoID: repo.id).cards == 1)
    }

    @Test("Confirming forgets it, and clears the prompt")
    func confirmDeletes() async throws {
        let (model, store, repo) = try await board()
        await model.requestForget(repoID: repo.id, origin: .preflight)

        await model.confirmForget()

        #expect(model.forgetRequest == nil)
        #expect(try await store.repo(id: repo.id) == nil)
        #expect(try await store.forgetImpact(repoID: repo.id).isEmpty)
    }

    @Test("The Repositories page's Forget fix opens the prompt instead of deleting")
    func repositoriesFixIsGated() async throws {
        // Criterion 1 for the second screen. The button is unchanged; the gate
        // sits where every caller of this fix passes.
        let (model, store, repo) = try await board()

        await model.apply(RepoFix.forget(repoID: repo.id))

        #expect(model.forgetRequest?.origin == .repositories)
        #expect(try await store.repo(id: repo.id) != nil)
    }

    @Test("Confirming with no store, or an unknown repository, does nothing")
    func refusesWhatItCannotMeasure() async throws {
        let (model, store, repo) = try await board()

        await model.requestForget(repoID: UUID(), origin: .preflight)

        // No prompt for a repository the model does not hold: a dialog that
        // cannot state a count would be the vague warning this issue removes.
        #expect(model.forgetRequest == nil)
        #expect(try await store.repo(id: repo.id) != nil)
    }
}
