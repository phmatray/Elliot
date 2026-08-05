import ElliotIPC
import ElliotStore
import Foundation
import MCP

/// Follows the runs a move started. `board_move_card` returns as soon as a run
/// is queued, so this is the only way an agent learns how one ended.
struct ListRunsTool: BoardTool {
    var tool: Tool {
        Tool(
            name: "board_list_runs",
            description: """
                List skill runs, most recent first, with their state and cost. \
                Use this to follow a move that started a run.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "card_id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer"), "default": .int(20)]),
                ]),
            ]),
            annotations: .init(title: "List runs", readOnlyHint: true)
        )
    }

    func call(_ args: [String: Value], bridge: AppBridge) async throws -> CallTool.Result {
        let cardID = args["card_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        let limit = args["limit"]?.intValue ?? 20

        switch bridge.read(.listRuns(cardID: cardID, limit: limit)) {
        case .live(let response):
            return .render(response) { payload in
                guard case .runs(let runs) = payload else { return nil }
                return ["runs": .encoding(runs), "source": .string("live")]
            }
        case .offline(let store):
            let runs = try await store.runs(cardID: cardID, limit: limit).map(RunDTO.init)
            return .ok(["runs": .encoding(runs), "source": .string("offline-db")])
        }
    }
}
