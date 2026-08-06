import ElliotIPC
import ElliotStore
import MCP

/// Answers the question an agent actually has — "which card should I act on,
/// and what happens if I do" — instead of the one board_list_cards answers.
///
/// The ranking is `rankNextSteps`, the pure function in `ElliotModel` the app
/// reads from too, and it decides by calling the same `evaluateMove` a real
/// move calls. That is what lets this tool *predict* board_move_card rather
/// than guess: a transition table written out again here would be a second copy
/// of the rules, and the copy is what drifts.
///
/// Because that function is pure, the answer survives Elliot being down — the
/// snapshot path ranks the same candidates the same way, through
/// `OfflineBoard.nextPage`, and never through a second implementation.
struct NextTool: BoardTool {
    var tool: Tool {
        Tool(
            name: "board_next",
            description: """
                What to do next on the Elliot board, ranked. Reach for this before \
                board_list_cards: that one returns cards and leaves the rules to you, \
                this one answers "which card should I act on, and what happens if I do".

                Each item names the single column the card goes to next, the skill that \
                move would trigger (create-issue, implement-issue, merge-pr), and whether \
                moving it right now would actually start that work — with the same \
                `blockCode` board_move_card would return if it were refused. Ready items \
                come first, then the cards nearest to done, because finishing work already \
                in flight beats starting more.

                Blocked cards are listed too, with their reason: "nothing is ready and here \
                is why" is an answer, an empty list is not. `readyCount` counts every ready \
                candidate, not only the ones on this page. Cards in `done` are not \
                candidates and are not counted.

                A ready inReview→done item means the merge will proceed with **no follow-up \
                issues filed**; pass `follow_ups` to board_move_card if you want some. \
                Reads only — nothing here moves a card.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "repo": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Repository as owner/name, or its absolute path. Omit for the whole board."
                        ),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "default": .int(ElliotPaging.nextLimitDefault),
                        "description": .string(
                            "How many ranked items to return. Capped at \(ElliotPaging.nextLimitMax); the answer says so when the cap applied."
                        ),
                    ]),
                ]),
            ]),
            annotations: .init(
                title: "What to do next",
                readOnlyHint: true,
                // Reads Elliot's own database. Nothing outside this machine is
                // consulted, and no run is started.
                openWorldHint: false
            )
        )
    }

    func call(_ args: [String: Value], bridge: any BridgeProviding) async throws -> CallTool.Result {
        let repo = args["repo"]?.stringValue
        // Unclamped on purpose: the app has to see the number the caller wrote,
        // or `limitCappedFrom` comes back nil for every request and the cap is
        // applied silently.
        let requested = try args.limit() ?? 0

        switch await bridge.read(.next(repo: repo, limit: requested)) {
        case .live(let response):
            return try .render(response) { payload in
                guard case .next(let page) = payload else { return nil }
                return try ToolOutput.nextFields(page, source: "live", extraNote: nil)
            }
        case .offline(let store, let reason):
            let (limit, cappedFrom) = ElliotPaging.clamp(
                requested,
                default: ElliotPaging.nextLimitDefault,
                max: ElliotPaging.nextLimitMax
            )
            let page = try await OfflineBoard.nextPage(
                store: store,
                repoID: try OfflineBoard.filter(repo, in: try await store.repos()).repoID,
                limit: limit,
                cappedFrom: cappedFrom
            )
            let fields = try ToolOutput.nextFields(
                page, source: "offline-db", extraNote: ToolOutput.offlineNote(reason)
            )
            return try .ok(fields)
        }
    }
}
