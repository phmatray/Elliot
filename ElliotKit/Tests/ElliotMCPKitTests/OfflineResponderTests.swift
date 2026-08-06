import ElliotIPC
import ElliotModel
import ElliotStore
import Foundation
import MCP
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

// MARK: - Rendering one outcome

/// What `CallTool.Result.render` adds on top of a tool's own fields.
///
/// Its own suite because the trap is in none of the tools: `render` attaches
/// `source` and the snapshot sentence for all of them, and the two that also
/// have something to say about their page are the ones a naive implementation
/// silences.
@Suite("Rendering one answer, live or from the snapshot")
struct OutcomeRenderingTests {

    @Test("The snapshot note is prepended to the note the tool already wrote, not put in its place")
    func snapshotNoteDoesNotReplaceTheToolsOwn() throws {
        // `board_list_cards` and `board_list_runs` attach both. An
        // implementation that *assigns* `note` instead of composing it drops
        // "Showing 2 of 5" — and nothing else in the suite would notice, because
        // every other tool has only the one note to attach.
        let outcome = BridgeOutcome.offline(.ok(.repos([])), .appNotRunning)

        let result = try CallTool.Result.render(outcome) { _ in
            var fields: [String: Value] = ["total": .int(0)]
            ToolOutput.attachNote(&fields, "Showing 2 of 5; the rest were left out.")
            return fields
        }

        let rendered = try answer(result)
        #expect(!rendered.isError)
        #expect(rendered.source == "offline-db")
        #expect(rendered.note.contains("Elliot is not running"))
        #expect(rendered.note.contains("Showing 2 of 5"))
        // Order matters as well as presence: the snapshot caveat qualifies
        // everything after it, so it goes first.
        #expect(rendered.note.hasPrefix("Elliot is not running"))
    }

    @Test("A snapshot served because the app did not answer does not claim the app is down")
    func unreachableIsItsOwnStory() throws {
        let outcome = BridgeOutcome.offline(.ok(.repos([])), .appUnreachable)

        let rendered = try answer(try CallTool.Result.render(outcome) { _ in ["total": .int(0)] })

        #expect(rendered.note.contains("did not answer"))
        #expect(!rendered.note.contains("Elliot is not running"))
    }

    @Test("A live answer says live and adds no note of its own")
    func liveAnswerCarriesNoSnapshotNote() throws {
        let rendered = try answer(
            try CallTool.Result.render(.live(.ok(.repos([])))) { _ in ["total": .int(0)] }
        )

        #expect(rendered.source == "live")
        #expect(rendered.note.isEmpty)
    }

    @Test("A refusal is rendered in the app's own words, with no source and no snapshot note")
    func refusalIsRenderedVerbatim() throws {
        // The helper never rewords a refusal it did not decide, and never
        // labels one `offline-db`: there is no answer to attribute a source to.
        let outcome = BridgeOutcome.offline(
            .failure(code: .cardNotFound, message: "No card with id 7.", hint: "Try board_list_cards."),
            .appUnreachable
        )

        let rendered = try answer(try CallTool.Result.render(outcome) { _ in ["unused": .bool(true)] })

        #expect(rendered.isError)
        #expect(rendered.error == ElliotErrorCode.cardNotFound.rawValue)
        #expect(rendered.message == "No card with id 7.")
        #expect(rendered.hint == "Try board_list_cards.")
        #expect(rendered.source == nil)
        #expect(rendered.note.isEmpty)
    }

    @Test("A payload the tool cannot read is an internal_error, not an empty answer")
    func unreadablePayloadIsAnError() throws {
        // Kept from the response-only form: a body returning nil used to be the
        // one way a tool could say "the app and this helper are different
        // builds", and an empty object under `isError: false` gets believed.
        let rendered = try answer(try CallTool.Result.render(.live(.ok(.repos([])))) { _ in nil })

        #expect(rendered.isError)
        #expect(rendered.error == "internal_error")
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
