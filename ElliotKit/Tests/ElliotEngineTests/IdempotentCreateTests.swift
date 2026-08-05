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

private struct Board {
    var store: BoardStore
    var service: BoardService
    var one: Repo
    var two: Repo

    static func make() async throws -> Board {
        let store = try BoardStore.inMemory()
        let one = Repo(path: "/tmp/one", nameWithOwner: "acme/one", displayName: "one")
        let two = Repo(path: "/tmp/two", nameWithOwner: "acme/two", displayName: "two")
        try await store.saveRepo(one)
        try await store.saveRepo(two)
        return Board(
            store: store,
            service: BoardService(store: store, launcher: SilentLauncher()),
            one: one,
            two: two
        )
    }
}

/// Creating a card twice must make one card — and creating two cards that are
/// not the same must never be mistaken for that.
///
/// Untested, this was a permanent outage waiting to happen: the lookup treated
/// an empty key as "no key" and the column stored it as a value, so the first
/// `idempotency_key: ""` poisoned the unique index and every later create in
/// every repository failed. There is no delete tool, so nothing could clear it.
@Suite("Creating a card once")
struct IdempotentCreateTests {

    @Test("Without a key, every call makes its own card")
    func noKeyMeansNoDeduplication() async throws {
        let board = try await Board.make()

        var ids: Set<UUID> = []
        for index in 0..<3 {
            let created = try await board.service.createCard(
                repoID: board.one.id, title: "Card \(index)"
            )
            #expect(!created.alreadyExisted)
            ids.insert(created.card.id)
        }

        #expect(ids.count == 3)
        #expect(try await board.store.cardCount() == 3)
    }

    @Test("The same key twice returns the first card and writes nothing")
    func sameKeyReturnsTheFirstCard() async throws {
        let board = try await Board.make()

        let first = try await board.service.createCard(
            repoID: board.one.id, title: "Stream the run log", idempotencyKey: "run-log"
        )
        let second = try await board.service.createCard(
            repoID: board.one.id, title: "Something else entirely", idempotencyKey: "run-log"
        )

        #expect(!first.alreadyExisted)
        #expect(second.alreadyExisted)
        #expect(second.card.id == first.card.id)
        // The answer is the card that exists, not the title of the request that
        // lost — a retry must not appear to have rewritten anything.
        #expect(second.card.title == "Stream the run log")
        #expect(try await board.store.cardCount() == 1)
    }

    @Test("An empty key means no key, and does not poison the next create")
    func emptyKeyIsNotAKey() async throws {
        let board = try await Board.make()

        let first = try await board.service.createCard(
            repoID: board.one.id, title: "First", idempotencyKey: ""
        )
        let second = try await board.service.createCard(
            repoID: board.one.id, title: "Second", idempotencyKey: ""
        )
        // A different repository, because the index is board-wide: stored, an
        // empty key would take the whole board down, not one repository.
        let third = try await board.service.createCard(
            repoID: board.two.id, title: "Third", idempotencyKey: ""
        )

        #expect(!first.alreadyExisted)
        #expect(!second.alreadyExisted)
        #expect(!third.alreadyExisted)
        #expect(Set([first.card.id, second.card.id, third.card.id]).count == 3)
        // Stored as nothing, so the column holds no empty strings to collide.
        #expect(first.card.idempotencyKey == nil)
        #expect(try await board.store.cardCount() == 3)
    }

    @Test("A key reused in another repository answers with the card it already named")
    func keysAreUniqueBoardWide() async throws {
        // Deliberate, and the reason the tool description says to derive the key
        // from the repository too: the lookup names only the key, so one that
        // could repeat across repositories would answer with an arbitrary one of
        // them and the second create would go through half the time.
        let board = try await Board.make()

        let first = try await board.service.createCard(
            repoID: board.one.id, title: "Add a licence", idempotencyKey: "add-licence"
        )
        let second = try await board.service.createCard(
            repoID: board.two.id, title: "Add a licence", idempotencyKey: "add-licence"
        )

        #expect(second.alreadyExisted)
        #expect(second.card.id == first.card.id)
        #expect(second.card.repoID == board.one.id)
        #expect(try await board.store.cardCount(repoID: board.two.id) == 0)
    }

    @Test("A key that named nothing yet makes a card")
    func unseenKeyCreates() async throws {
        let board = try await Board.make()
        let created = try await board.service.createCard(
            repoID: board.one.id, title: "Fresh", idempotencyKey: "fresh"
        )

        #expect(!created.alreadyExisted)
        #expect(created.card.idempotencyKey == "fresh")
        #expect(try await board.store.card(idempotencyKey: "fresh")?.id == created.card.id)
    }
}
