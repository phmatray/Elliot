import ElliotIPC
import ElliotModel
import ElliotStore
import Foundation
import MCP
import Testing

@testable import ElliotMCPKit

/// What the helper refuses, and what it says instead of an empty answer.
@Suite("Refusing from a snapshot")
struct SnapshotRefusalTests {

    @Test("A card id nothing matches is refused, not answered with an empty run list")
    func unknownCardOnListRuns() async throws {
        // The running app refuses this, and the two paths have to agree: "this
        // card has no runs yet" tells an agent to keep polling, and there is
        // nothing to poll for. Same defect as answering an unknown repository
        // with the whole board, one tool over.
        let repo = makeRepo()
        let card = makeCard(repoID: repo.id)
        let store = try await makeStore(repos: [repo], cards: [card])
        let server = ElliotMCPServer(bridge: StubBridge.snapshot(store))

        let answer = try await call(
            server, "board_list_runs", ["card_id": .string(UUID().uuidString)]
        )

        #expect(answer.isError)
        #expect(answer.error == ElliotErrorCode.cardNotFound.rawValue)
        #expect(answer["runs"] == nil)

        // The control: a card that exists with no runs is an empty page, not a
        // refusal. Without this, refusing everything would pass the test above.
        let empty = try await call(
            server, "board_list_runs", ["card_id": .string(card.id.uuidString)]
        )
        #expect(!empty.isError)
        #expect(empty["total"]?.intValue == 0)
    }

    @Test("A card that already carries its issue is not said to be waiting on a pull request")
    func alreadyFiledCardIsDescribedHonestly() async throws {
        // `.noAction` covers two different pieces of news, and the snapshot path
        // used to give both of them the in-flight one: "Elliot moves this card
        // itself when it notices the pull request is ready". For a backlog card
        // that already has an issue number there is no pull request and nothing
        // will ever move it, so an agent that believed the sentence would stop.
        let repo = makeRepo()
        let filed = makeCard(repoID: repo.id, title: "Already filed", column: .backlog, issueNumber: 42)
        let store = try await makeStore(repos: [repo], cards: [filed])

        let answer = try await call(ElliotMCPServer(bridge: StubBridge.snapshot(store)), "board_next")

        let item = try #require(answer["items"]?[0])
        #expect(item["blockCode"]?.stringValue == NextBlockCode.nothingToTrigger)
        #expect(item["blockReason"]?.stringValue?.contains("pull request") == false)
        #expect(item["blockReason"]?.stringValue?.contains("already carries") == true)
    }

    @Test("A limit below one is refused rather than read as the default")
    func negativeLimitIsRefused() async throws {
        // `limit: remaining - seen` going negative would otherwise answer a
        // hundred rows under isError: false, with `limit` and `truncated`
        // describing a page nobody asked for.
        for tool in ["board_list_cards", "board_list_runs", "board_next"] {
            let answer = try await call(
                ElliotMCPServer(bridge: StubBridge()), tool, ["limit": .int(-5)]
            )
            #expect(answer.isError, "\(tool)")
            #expect(answer.error == "bad_argument", "\(tool)")
            #expect(answer.message.contains("limit"), "\(tool)")
        }
    }
}

/// What the helper says when the file it can read is not a board it can read.
@Suite("Opening a database this helper does not understand")
struct SnapshotOpenFailureTests {

    @Test("A newer schema is named as a version skew, not as Elliot being down")
    func schemaTooNewIsNotAppUnavailable() {
        // "Elliot is not running — open Elliot.app" is precisely the action that
        // does not help here: launching the app makes reads work by going live
        // and teaches nobody that the helper is stale.
        guard case .failure(let code, let message, let hint) =
            AppBridge.failure(for: StoreError.schemaTooNew)
        else {
            Issue.record("expected a refusal")
            return
        }

        #expect(code == .protocolMismatch)
        #expect(message.contains("newer version of Elliot"))
        #expect(hint?.contains("claude mcp add") == true)
    }

    @Test("A board that was never set up says to open the app once")
    func schemaMissingSaysWhatToDo() {
        guard case .failure(let code, let message, _) =
            AppBridge.failure(for: StoreError.schemaMissing)
        else {
            Issue.record("expected a refusal")
            return
        }

        #expect(code == .appUnavailable)
        #expect(message.contains("has not been set up"))
    }

    @Test("Any other failure still says the database could not be opened")
    func otherFailuresAreStillReported() {
        guard case .failure(let code, let message, _) =
            AppBridge.failure(for: StoreError.readOnly)
        else {
            Issue.record("expected a refusal")
            return
        }

        #expect(code == .appUnavailable)
        #expect(message.contains("could not be opened"))
    }
}
