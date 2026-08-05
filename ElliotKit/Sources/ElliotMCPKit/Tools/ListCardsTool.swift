import ElliotIPC
import ElliotModel
import ElliotStore
import MCP

/// Reads the board.
///
/// Falls back to a read-only snapshot of the database when Elliot is down, and
/// labels the answer `offline-db` rather than passing a snapshot off as the
/// live board. The snapshot branch has to answer the *same* questions the live
/// one does — an unknown repository refused, a held card's `activeRunID`
/// filled, a cut page said to be cut — because nothing in the reply tells an
/// agent which branch served it, so a snapshot that quietly answered a wider
/// question got believed.
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
            annotations: .init(title: "List board cards", readOnlyHint: true, openWorldHint: false)
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

        switch await bridge.read(.listCards(repo: repo, column: column, limit: requested)) {
        case .live(let response):
            return try .render(response) { payload in
                guard case .cards(let page) = payload else { return nil }
                var fields = ToolOutput.pageFields(
                    total: page.total, limit: page.limit,
                    truncated: page.truncated, cappedFrom: page.limitCappedFrom
                )
                fields["cards"] = try Value.encoding(page.cards)
                fields["source"] = .string("live")
                ToolOutput.attachNote(&fields, ToolOutput.pageNote(
                    shown: page.cards.count, total: page.total,
                    truncated: page.truncated, limit: page.limit, cappedFrom: page.limitCappedFrom
                ))
                return fields
            }

        case .offline(let store):
            let (limit, cappedFrom) = ElliotPaging.clamp(
                requested,
                default: ElliotPaging.cardLimitDefault,
                max: ElliotPaging.cardLimitMax
            )
            let repos = try await store.repos()
            // `.all` and "you named a repository I do not know" are different
            // values, not one nil. Collapsing them is what made a typo return
            // the whole board as a success.
            let filter = try OfflineBoard.filter(repo, in: repos)
            let cards = try await store.cards(repoID: filter.repoID, column: column, limit: limit)
            let total = try await store.cardCount(repoID: filter.repoID, column: column)
            let active = try await store.activeRuns(cardIDs: cards.map(\.id))
            let names = OfflineBoard.namesByID(repos)
            let page = CardPage(
                cards: cards.map { card in
                    CardDTO(
                        card: card,
                        repoName: names[card.repoID] ?? "?",
                        activeRunID: active[card.id]?.id
                    )
                },
                total: total,
                limit: limit,
                limitCappedFrom: cappedFrom
            )
            var fields = ToolOutput.pageFields(
                total: page.total, limit: page.limit,
                truncated: page.truncated, cappedFrom: page.limitCappedFrom
            )
            fields["cards"] = try Value.encoding(page.cards)
            fields["source"] = .string("offline-db")
            ToolOutput.attachNote(
                &fields,
                ToolOutput.offlineNote,
                ToolOutput.pageNote(
                    shown: page.cards.count, total: page.total,
                    truncated: page.truncated, limit: page.limit, cappedFrom: page.limitCappedFrom
                )
            )
            return try .ok(fields)
        }
    }
}
