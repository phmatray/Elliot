import ElliotIPC
import ElliotModel
import ElliotStore
import Foundation
import Testing

@testable import ElliotMCPKit

/// The snapshot half of the wire, asserted in the wire's own vocabulary.
///
/// `OfflineResponder` answers an `ElliotRequest` with an `ElliotResponse` — the
/// same type the running app answers with — which is what lets a tool render one
/// answer instead of carrying a second implementation of the app's query. What
/// those answers look like once rendered as JSON is `OfflineBoardTests`; this
/// suite is about the answer itself, before any tool has seen it.
@Suite("Answering a read from the snapshot")
struct OfflineResponderTests {

    // MARK: - Refusing what the running app refuses

    @Test("A repository nobody registered is refused, and the known names are named")
    func unknownRepoIsRefused() async throws {
        // `.all` and "you named a repository I do not know" are different
        // answers, not one nil. Collapsing them is what made a typo return the
        // whole board as a success — and it was fixed one tool at a time,
        // because each tool held its own copy of the question.
        let elliot = makeRepo("phmatray/Elliot")
        let koine = makeRepo("Atypical-Consulting/Koine")
        let store = try await makeStore(repos: [elliot, koine], cards: [makeCard(repoID: elliot.id)])

        let response = await OfflineResponder(store: store)
            .respond(to: .listCards(repo: "phmatray/Eliot", column: nil, limit: 0))

        let denial = try #require(refusal(response))
        #expect(denial.code == .repoNotFound)
        #expect(denial.hint?.contains("phmatray/Elliot") == true)
        #expect(denial.hint?.contains("Atypical-Consulting/Koine") == true)
    }

    @Test("A card id nothing matches is card_not_found, not an empty card")
    func unknownCardIsRefused() async throws {
        let store = try await makeStore(repos: [makeRepo()])

        let response = await OfflineResponder(store: store).respond(to: .getCard(id: UUID()))

        #expect(refusal(response)?.code == .cardNotFound)
    }

    @Test("Listing the runs of a card that does not exist is refused, not answered with an empty page")
    func unknownCardOnListRunsIsRefused() async throws {
        // "This card has no runs yet" tells an agent to keep polling, and there
        // is nothing to poll for. Only one of the two answers is true.
        let repo = makeRepo()
        let card = makeCard(repoID: repo.id)
        let store = try await makeStore(repos: [repo], cards: [card])
        let responder = OfflineResponder(store: store)

        let missing = await responder.respond(to: .listRuns(cardID: UUID(), limit: 0))
        #expect(refusal(missing)?.code == .cardNotFound)

        // The control: a card that exists with no runs *is* an empty page.
        // Without it, refusing everything would pass the assertion above.
        let empty = try runs(await responder.respond(to: .listRuns(cardID: card.id, limit: 0)))
        #expect(empty.total == 0)
        #expect(empty.runs.isEmpty)
    }

    // MARK: - Paging, counted against the whole board

    @Test("The server's own cap is applied, and the number the caller asked for is reported")
    func limitIsClampedAndTheCapIsNamed() async throws {
        // Reported, not silently applied: a cap nobody is told about is the same
        // defect as a silent truncation.
        let repo = makeRepo()
        let store = try await makeStore(repos: [repo], cards: [makeCard(repoID: repo.id)])

        let page = try cards(
            await OfflineResponder(store: store)
                .respond(to: .listCards(repo: nil, column: nil, limit: 9999))
        )

        #expect(page.limit == ElliotPaging.cardLimitMax)
        #expect(page.limitCappedFrom == 9999)
    }

    @Test("A cut page counts every card the filter matched, not the ones that fitted")
    func totalSpansTheWholeFilter() async throws {
        let repo = makeRepo()
        let seeded = (0..<5).map {
            makeCard(repoID: repo.id, title: "Card \($0)", orderIndex: Double(1024 * ($0 + 1)))
        }
        let store = try await makeStore(repos: [repo], cards: seeded)

        let page = try cards(
            await OfflineResponder(store: store)
                .respond(to: .listCards(repo: nil, column: nil, limit: 2))
        )

        #expect(page.cards.count == 2)
        #expect(page.total == 5)
        #expect(page.truncated)
    }

    // MARK: - A held card reads as held

    @Test("A card a run is holding carries that run's id, and a free card carries none")
    func activeRunIsFilled() async throws {
        // Absent means "no run holds this card" and nothing else, so an answer
        // that skipped the lookup would report every held card as movable.
        let repo = makeRepo()
        let held = makeCard(repoID: repo.id, title: "Held", column: .todo, orderIndex: 1024)
        let free = makeCard(repoID: repo.id, title: "Free", column: .todo, orderIndex: 2048)
        let running = makeRun(cardID: held.id, repoID: repo.id, kind: .implementIssue, state: .running)
        let done = makeRun(cardID: free.id, repoID: repo.id, state: .succeeded)
        let store = try await makeStore(repos: [repo], cards: [held, free], runs: [running, done])
        let responder = OfflineResponder(store: store)

        let page = try cards(await responder.respond(to: .listCards(repo: nil, column: nil, limit: 0)))
        var byTitle: [String: CardDTO] = [:]
        for card in page.cards { byTitle[card.title] = card }
        #expect(byTitle["Held"]?.activeRunID == running.id)
        #expect(byTitle["Free"]?.activeRunID == nil)

        // The same fact through the single-card request, which is a different
        // query and used to be a different implementation.
        let one = try card(await responder.respond(to: .getCard(id: held.id)))
        #expect(one.activeRunID == running.id)
        #expect(one.repo == "phmatray/Elliot")
    }

    // MARK: - A write never falls back

    @Test("A write is refused as read_only rather than served from the snapshot")
    func writesAreRefused() async throws {
        // Writing a column change straight to SQLite would move a card without
        // firing its rule, which is the bug the whole architecture prevents. The
        // responder holds the same line the bridge does, one layer down.
        let repo = makeRepo()
        let card = makeCard(repoID: repo.id)
        let store = try await makeStore(repos: [repo], cards: [card])

        let response = await OfflineResponder(store: store)
            .respond(to: .moveCard(id: card.id, to: .todo, followUps: []))

        #expect(refusal(response)?.code == .readOnly)
    }
}

// MARK: - Reading a response

private struct WrongPayload: Error, CustomStringConvertible {
    let expected: String
    var description: String { "the responder did not answer with \(expected)" }
}

/// The refusal in a response, or nil when it answered.
private func refusal(
    _ response: ElliotResponse
) -> (code: ElliotErrorCode, message: String, hint: String?)? {
    guard case .failure(let code, let message, let hint) = response else { return nil }
    return (code, message, hint)
}

private func cards(_ response: ElliotResponse) throws -> CardPage {
    guard case .ok(.cards(let page)) = response else { throw WrongPayload(expected: "a page of cards") }
    return page
}

private func card(_ response: ElliotResponse) throws -> CardDTO {
    guard case .ok(.card(let card)) = response else { throw WrongPayload(expected: "one card") }
    return card
}

private func runs(_ response: ElliotResponse) throws -> RunPage {
    guard case .ok(.runs(let page)) = response else { throw WrongPayload(expected: "a page of runs") }
    return page
}
