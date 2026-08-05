import ElliotIPC
import Foundation
import MCP

/// Marks proposals rejected. They stay on the analysis, so it still reads as
/// what it found — including what was turned down.
///
/// `decided` here means the id named a proposal that exists, not that this call
/// is what rejected it: the app discards the atomic claim result internally, so
/// one already decided by an earlier or concurrent call comes back the same way.
/// The description says so rather than let `decided` overclaim.
struct RejectProposalsTool: BoardTool {
    var tool: Tool {
        Tool(
            name: "board_reject_proposals",
            description: """
                Mark proposals as rejected. They stay on the analysis so it still \
                reads as what it found, including what was turned down. \
                `decided` in the result means the id named a proposal that \
                exists, not that this call is what rejected it — one already \
                decided by an earlier or concurrent call is reported the same way.
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
                title: "Reject proposals",
                readOnlyHint: false,
                destructiveHint: false,
                openWorldHint: false
            )
        )
    }

    func call(_ args: [String: Value], bridge: any BridgeProviding) async throws -> CallTool.Result {
        let ids = try ToolOutput.proposalIDs(args)
        let response = await bridge.write(.rejectProposals(ids: ids))
        return try .render(response) { payload in
            guard case .proposalsDecided(let decision) = payload else { return nil }
            return try ToolOutput.decisionFields(decision)
        }
    }
}
