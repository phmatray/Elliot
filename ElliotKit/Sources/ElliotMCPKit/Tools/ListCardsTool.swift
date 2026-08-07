import ElliotIPC
import ElliotModel
import ElliotStore
import MCP

/// Reads the board.
///
/// Falls back to a read-only snapshot of the database when Elliot is down, and
/// labels the answer `offline-db` rather than passing a snapshot off as the
/// live board. The snapshot answers the *same* questions the live board does —
/// an unknown repository refused, a held card's `activeRunID` filled, a cut page
/// said to be cut — because `OfflineResponder` answers them in the same type,
/// and this tool renders whichever answer it is handed. It used to be a request
/// rather than a guarantee: this tool held a second implementation of that
/// query, and a snapshot that quietly answered a wider question got believed,
/// since nothing in the reply tells an agent which branch served it.
struct ListCardsTool: BoardTool {
    var tool: Tool {
        Tool(
            name: "board_list_cards",
            description: """
                List Elliot board cards. Optionally filter by repository (owner/name or \
                absolute path) and by column (backlog, todo, inProgress, inReview, done). \
                Returns each card's story, issue and pull-request numbers when it has them.

                `activeRunID` is present exactly when a run is holding the card, which is \
                why a move would be refused; absent means no run holds it.

                The answer is a page, not a list: `total` counts everything the filter \
                matched, `truncated` says the rest were left out, and `limit_capped_from` \
                appears when you asked for more than the server will send. Ordered by \
                repository, then board column, then position within the column — stable \
                across calls, so "the first ten" means the same ten twice.

                An unknown repository is refused with `repo_not_found` and the known names, \
                never silently widened to the whole board.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "repo": .object([
                        "type": .string("string"),
                        "description": .string("Repository as owner/name. Omit for all repositories."),
                    ]),
                    "column": .object([
                        "type": .string("string"),
                        "enum": .array(Column.allCases.map { .string($0.rawValue) }),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "default": .int(ElliotPaging.cardLimitDefault),
                        "description": .string(
                            "Capped at \(ElliotPaging.cardLimitMax). Filter by repo or column rather than raising it."
                        ),
                    ]),
                ]),
            ]),
            annotations: .init(
                title: "List board cards",
                readOnlyHint: true,
                // Elliot's own rows. Nothing is fetched and no run is started.
                openWorldHint: false
            )
        )
    }

    func call(_ args: [String: Value], bridge: any BridgeProviding) async throws -> CallTool.Result {
        let repo = args["repo"]?.stringValue
        let column = try args.column("column")
        // The caller's own number goes on the wire. Clamping it here first would
        // hand the app a limit that never exceeds its cap, and `limitCappedFrom`
        // would come back nil for every request — a silent cap, which is the
        // same defect as a silent truncation.
        let requested = try args.limit() ?? 0

        let outcome = await bridge.read(.listCards(repo: repo, column: column, limit: requested))
        return try .render(outcome) { payload in
            guard case .cards(let page) = payload else { return nil }
            var fields = ToolOutput.pageFields(
                total: page.total, limit: page.limit,
                truncated: page.truncated, cappedFrom: page.limitCappedFrom
            )
            fields["cards"] = try Value.encoding(page.cards)
            ToolOutput.attachNote(&fields, ToolOutput.pageNote(
                shown: page.cards.count, total: page.total,
                truncated: page.truncated, limit: page.limit, cappedFrom: page.limitCappedFrom
            ))
            return fields
        }
    }
}
