import ElliotIPC
import ElliotModel
import Foundation
import MCP

/// Moves a card, which is how every run in Elliot starts.
///
/// The transition itself decides what runs — the rule engine in the app owns
/// that table, and this tool never second-guesses it.
struct MoveCardTool: BoardTool {
    var tool: Tool {
        Tool(
            name: "board_move_card",
            description: """
                Move a card to another column. This is how work is driven: \
                backlog→todo files a GitHub issue, todo→inProgress implements it and \
                opens a pull request, inReview→done merges it. Those runs take minutes \
                to tens of minutes; this returns as soon as the run is queued. \
                Poll board_list_runs to follow it. Moves that do not match one of those \
                three transitions simply reposition the card.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "card_id": .object(["type": .string("string")]),
                    "to": .object([
                        "type": .string("string"),
                        "enum": .array(Column.allCases.map { .string($0.rawValue) }),
                    ]),
                    "follow_ups": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string(
                            "Follow-up work to file as issues after a merge. Omit for none."
                        ),
                    ]),
                ]),
                "required": .array([.string("card_id"), .string("to")]),
            ]),
            annotations: .init(title: "Move a card", readOnlyHint: false, destructiveHint: false)
        )
    }

    func call(_ args: [String: Value], bridge: AppBridge) async throws -> CallTool.Result {
        guard let id = args["card_id"]?.stringValue.flatMap(UUID.init(uuidString:)) else {
            return .failure(code: "bad_argument", message: "card_id must be a UUID.")
        }
        guard let to = args["to"]?.stringValue.flatMap(Column.init(rawValue:)) else {
            return .failure(
                code: "bad_argument",
                message: "`to` must be one of: \(Column.allCases.map(\.rawValue).joined(separator: ", "))."
            )
        }
        // An omitted list means "no follow-ups", not "ask me" — the UI is the
        // only caller that gets to be asked.
        let followUps = args["follow_ups"]?.arrayValue?.compactMap(\.stringValue) ?? []

        let response = bridge.write(.moveCard(id: id, to: to, followUps: followUps))
        return .render(response) { payload in
            guard case .moved(let move) = payload else { return nil }
            var fields: [String: Value] = [
                "card_id": .string(move.cardID.uuidString),
                "from": .string(move.from),
                "to": .string(move.to),
                "summary": .string(move.summary),
            ]
            if let runID = move.runID { fields["run_id"] = .string(runID.uuidString) }
            if let triggered = move.triggered { fields["triggered"] = .string(triggered) }
            return fields
        }
    }
}
