import ElliotIPC
import ElliotStore
import Foundation
import MCP

/// Reads one card, with everything the agent needs to act on it: its story, the
/// issue and pull request it produced, the error that stopped its last run, and
/// the run holding it right now.
///
/// That last field is why the snapshot branch spends a second query rather than
/// building the DTO straight from the row: `activeRunID` absent means "no run
/// holds this card", so an offline answer that left it nil reported every held
/// card as movable.
struct GetCardTool: BoardTool {
    var tool: Tool {
        Tool(
            name: "board_get_card",
            description: """
                Fetch one Elliot card by id, with its story, issue, pull request, last error \
                and the id of the run holding it, if any.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "card_id": .object(["type": .string("string"), "description": .string("Card UUID.")]),
                ]),
                "required": .array([.string("card_id")]),
            ]),
            annotations: .init(
                title: "Get a card",
                readOnlyHint: true,
                // One row of Elliot's database. The issue URL on it was stored
                // by an earlier run, not fetched now.
                openWorldHint: false
            )
        )
    }

    func call(_ args: [String: Value], bridge: any BridgeProviding) async throws -> CallTool.Result {
        let id = try args.uuid("card_id")
        switch await bridge.read(.getCard(id: id)) {
        case .live(let response):
            return try .render(response) { payload in
                guard case .card(let card) = payload else { return nil }
                return ["card": try Value.encoding(card), "source": .string("live")]
            }
        case .offline(let store, let reason):
            guard let card = try await store.card(id: id) else {
                return .failure(code: "card_not_found", message: "No card with id \(id).")
            }
            let repoName = try await store.repo(id: card.repoID)?.nameWithOwner ?? "?"
            // Filled, not skipped: absent means "no run holds this card", so a
            // snapshot that left it nil would report every held card as movable.
            let activeRunID = try await store.activeRun(cardID: id)?.id
            let dto = CardDTO(card: card, repoName: repoName, activeRunID: activeRunID)
            var fields: [String: Value] = [
                "card": try Value.encoding(dto),
                "source": .string("offline-db"),
            ]
            ToolOutput.attachNote(&fields, ToolOutput.offlineNote(reason))
            return try .ok(fields)
        }
    }
}
