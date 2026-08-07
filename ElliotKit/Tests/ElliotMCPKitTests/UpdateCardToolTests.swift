import ElliotIPC
import ElliotModel
import ElliotStore
import Foundation
import MCP
import Testing

@testable import ElliotMCPKit

/// `board_update_card` exists for what it refuses.
///
/// Once a card carries an issue number github.com is the record, and the card
/// has to stop being editable: an agent that corrects the board after filing
/// leaves two texts with nothing to reconcile them. The rule itself is
/// `BoardService`'s and `ElliotEngineTests` pins it. What this suite pins is the
/// half this module owns — that the refusal reaches the agent intact, that the
/// correction reaches the app whole, and that none of it can be answered from
/// the read-only snapshot.
///
/// Two neighbours already cover the rest and are not repeated here:
/// `RunReportingTests.alreadyFiledIsItsOwnRefusal` (the code is
/// `card_already_filed` and never `read_only`) and
/// `RunReportingTests.updateWithoutTitleIsRefused` (a correction with no title).
@Suite("board_update_card")
struct UpdateCardToolTests {

    @Test("A card nobody has filed is corrected, and the correction reaches the app whole")
    func unfiledCardIsUpdated() async throws {
        let log = RequestLog()
        let id = UUID()
        let updated = CardDTO(
            id: id,
            title: "Stream the run log, live",
            column: "backlog",
            repo: "phmatray/Elliot",
            story: .init(
                role: "developer",
                want: "the log streamed",
                benefit: "I can watch a failure happen",
                acceptanceCriteria: ["lines appear within a second"],
                narrative: "As a developer, I want the log streamed"
            ),
            body: "the note"
        )
        let bridge = StubBridge(onWrite: { request in
            log.record(request)
            return .ok(.card(updated))
        })

        let answer = try await call(
            ElliotMCPServer(bridge: bridge),
            "board_update_card",
            [
                "card_id": .string(id.uuidString),
                "title": .string("Stream the run log, live"),
                "body": .string("the note"),
                "role": .string("developer"),
                "want": .string("the log streamed"),
                "benefit": .string("I can watch a failure happen"),
                "acceptance_criteria": .array([.string("lines appear within a second")]),
            ]
        )

        #expect(!answer.isError)
        #expect(answer["card"]?["title"]?.stringValue == "Stream the run log, live")
        #expect(answer["card"]?["story"]?["role"]?.stringValue == "developer")

        // A replacement and not a patch, so the whole story has to arrive. Send
        // only the fields this call happened to mention and the app saves a card
        // with the rest silently dropped — which is indistinguishable, from the
        // board, from a user who deleted them.
        guard case .updateCard(let sent, let title, let body, let story)? = log.last else {
            Issue.record("the helper did not forward an updateCard request")
            return
        }
        #expect(sent == id)
        #expect(title == "Stream the run log, live")
        #expect(body == "the note")
        #expect(story?.role == "developer")
        #expect(story?.acceptanceCriteria == ["lines appear within a second"])
    }

    @Test("The refusal reaches the agent in the app's own words, carrying no card")
    func refusalIsCarriedVerbatim() async throws {
        // The wording is the app's — `MCPRequestHandler` builds it, and naming
        // the issue is pinned in `ElliotEngineTests`. What is asserted here is
        // that this tool does not reword, summarise or drop it. `.render` could
        // have swallowed the hint or answered `internal_error`, and an agent that
        // loses the pointer to github.com has nowhere left to make the edit.
        let bridge = StubBridge.refusing(
            .cardAlreadyFiled,
            "This card is filed as issue #123; edit the issue on github.com.",
            hint: "https://github.com/phmatray/Elliot/issues/123"
        )

        let answer = try await call(
            ElliotMCPServer(bridge: bridge),
            "board_update_card",
            ["card_id": .string(UUID().uuidString), "title": .string("Corrected")]
        )

        #expect(answer.isError)
        #expect(answer.message == "This card is filed as issue #123; edit the issue on github.com.")
        #expect(answer.hint == "https://github.com/phmatray/Elliot/issues/123")
        // Nothing was changed, so nothing comes back. A refusal that still
        // carried a card would read as "here is the card as it now stands", and
        // the agent would believe its edit had landed.
        #expect(answer["card"] == nil)
    }

    @Test("Correcting a card is a write, so a snapshot refuses it rather than serving it")
    func updateIsNeverServedOffline() async throws {
        let repo = makeRepo()
        let card = makeCard(repoID: repo.id, title: "Before")
        let store = try await makeStore(repos: [repo], cards: [card])
        let log = RequestLog()
        let bridge = StubBridge(
            isAppRunning: false,
            onRead: { request in
                log.record(request)
                return await StubBridge.snapshotOutcome(store, request)
            },
            onWrite: { _ in StubBridge.snapshotRefusesWrites }
        )

        let answer = try await call(
            ElliotMCPServer(bridge: bridge),
            "board_update_card",
            ["card_id": .string(card.id.uuidString), "title": .string("After")]
        )

        #expect(answer.isError)
        #expect(answer.error == ElliotErrorCode.appUnavailable.rawValue)
        #expect(answer["card"] == nil)
        // Not merely "it was refused": the read side must not be consulted at
        // all. A tool that reached the snapshot first would have a database
        // handle within reach of the one code path that must never have one.
        #expect(log.count == 0)
        #expect(answer.source == nil)
    }
}
