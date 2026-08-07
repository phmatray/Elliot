import ElliotIPC
import ElliotStore
import Foundation
import MCP

/// Reads one card, with everything the agent needs to act on it: its story, the
/// issue and pull request it produced, the error that stopped its last run, and
/// the run holding it right now.
///
/// That last field is why the snapshot spends a second query rather than
/// building the DTO straight from the row: `activeRunID` absent means "no run
/// holds this card", so an offline answer that left it nil reported every held
/// card as movable. The query lives in `OfflineResponder` now, beside the
/// running app's own, rather than in a second body here — which is where that
/// nil was, and where it had to be found separately.
struct GetCardTool: BoardTool {
    var tool: Tool {
        Tool(
            name: "board_get_card",
            description: """
                Fetch one Elliot card by id, with its story, issue, pull request, last error \
                and the id of the run holding it, if any. For a card waiting in In Review, \
                `prStatus` carries what GitHub last said about its pull request — CI, \
                mergeability and review as three separate facets, the names of the checks that \
                actually ran, and when and on which commit it was read. `ci: "no_checks"` means \
                nothing has judged the pull request, which is not the same as passing; \
                `isStale: true` means the reading is too old to rely on. An absent `prStatus` \
                means no reading exists, which is not an all-clear either.
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
        let outcome = await bridge.read(.getCard(id: id))
        return try .render(outcome) { payload in
            guard case .card(let card) = payload else { return nil }
            return ["card": try Value.encoding(card)]
        }
    }
}
