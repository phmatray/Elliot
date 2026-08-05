import ElliotIPC
import Foundation
import MCP

/// Turns proposals into Backlog cards, through the same `BoardService.createCard`
/// the New Card sheet uses.
///
/// Nothing is filed on GitHub by accepting: a card in Backlog runs nothing, and
/// it is the move to `todo` that opens an issue. Said in the description because
/// an agent that believed otherwise would stop short of the move it actually
/// wanted.
struct AcceptProposalsTool: BoardTool {
    var tool: Tool {
        Tool(
            name: "board_accept_proposals",
            description: """
                Turn proposals into Backlog cards. This files nothing on GitHub: \
                a card in Backlog runs nothing, and moving it to `todo` is what \
                opens an issue. Proposals already accepted or rejected are \
                skipped rather than duplicated.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "proposal_ids": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                ]),
                "required": .array([.string("proposal_ids")]),
            ]),
            annotations: .init(
                title: "Accept proposals",
                readOnlyHint: false,
                destructiveHint: false,
                openWorldHint: false
            )
        )
    }

    func call(_ args: [String: Value], bridge: any BridgeProviding) async throws -> CallTool.Result {
        let ids = try ToolOutput.proposalIDs(args)
        let response = await bridge.write(.acceptProposals(ids: ids))
        return try .render(response) { payload in
            guard case .proposalsDecided(let decision) = payload else { return nil }
            return try ToolOutput.decisionFields(decision)
        }
    }
}
