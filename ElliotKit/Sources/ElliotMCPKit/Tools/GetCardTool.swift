import ElliotIPC
import ElliotStore
import Foundation
import MCP

/// Reads one card, with everything the agent needs to act on it: its story, the
/// issue and pull request it produced, and the error that stopped its last run.
struct GetCardTool: BoardTool {
    var tool: Tool {
        Tool(
            name: "board_get_card",
            description: "Fetch one Elliot card by id, with its story, issue, pull request and last error.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "card_id": .object(["type": .string("string"), "description": .string("Card UUID.")]),
                ]),
                "required": .array([.string("card_id")]),
            ]),
            annotations: .init(title: "Get a card", readOnlyHint: true)
        )
    }

    func call(_ args: [String: Value], bridge: AppBridge) async throws -> CallTool.Result {
        guard let id = args["card_id"]?.stringValue.flatMap(UUID.init(uuidString:)) else {
            return .failure(code: "bad_argument", message: "card_id must be a UUID.")
        }
        switch bridge.read(.getCard(id: id)) {
        case .live(let response):
            return .render(response) { payload in
                guard case .card(let card) = payload else { return nil }
                return ["card": .encoding(card), "source": .string("live")]
            }
        case .offline(let store):
            guard let card = try await store.card(id: id) else {
                return .failure(code: "card_not_found", message: "No card with id \(id).")
            }
            let repoName = try await store.repo(id: card.repoID)?.nameWithOwner ?? "?"
            return .ok([
                "card": .encoding(CardDTO(card: card, repoName: repoName)),
                "source": .string("offline-db"),
            ])
        }
    }
}
