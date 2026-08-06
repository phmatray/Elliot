import ElliotIPC
import ElliotModel
import ElliotStore
import Foundation
import MCP

/// Reads what an analysis proposed. A read, so it answers from the snapshot when
/// Elliot is down — proposals are rows, and a row is a row whether or not the
/// app is up.
///
/// The snapshot resolves the repository through `OfflineResponder`, which
/// refuses a name it does not know exactly as the running app does. This tool
/// used to resolve it a second time, and the lesson — that a typo read as "no
/// filter" answers with every proposal on the board under `isError: false` —
/// had to be taught here after it had already been fixed twice elsewhere.
struct ListProposalsTool: BoardTool {
    var tool: Tool {
        Tool(
            name: "board_list_proposals",
            description: """
                List the user stories an analysis proposed. Give either \
                analysis_id or repo. Defaults to status: proposed — the ones \
                still needing a decision; pass status to see accepted or \
                rejected ones too. `grounded` is false when a story cites a \
                file that is not there — it may still be right, but it was not \
                checkable. `duplicate_hint` flags a story that looks like \
                something already on the board or already filed.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "analysis_id": .object(["type": .string("string")]),
                    "repo": .object(["type": .string("string")]),
                    "status": .object([
                        "type": .string("string"),
                        "enum": .array(ProposalStatus.allCases.map { .string($0.rawValue) }),
                        "default": .string("proposed"),
                    ]),
                    "limit": .object(["type": .string("integer"), "default": .int(100)]),
                ]),
            ]),
            annotations: .init(
                title: "List proposals",
                readOnlyHint: true,
                // Rows an earlier board_analyze_repo wrote. That tool is the one
                // annotated open; reading what it left behind is not.
                openWorldHint: false
            )
        )
    }

    func call(_ args: [String: Value], bridge: any BridgeProviding) async throws -> CallTool.Result {
        let analysisID = try args.optionalUUID("analysis_id")
        let repo = args["repo"]?.stringValue
        guard analysisID != nil || repo != nil else {
            throw ToolFailure(code: "bad_argument", message: "Give either analysis_id or repo.")
        }
        // Default to what still needs deciding: an agent asking "what did the
        // analysis find" means the open ones.
        let status = args["status"]?.stringValue ?? ProposalStatus.proposed.rawValue
        let limit = try args.limit() ?? 100

        let outcome = await bridge.read(.listProposals(
            analysisID: analysisID, repo: repo, status: status, limit: limit
        ))
        return try .render(outcome) { payload in
            guard case .proposals(let proposals) = payload else { return nil }
            return ["proposals": try Value.encoding(proposals)]
        }
    }
}
