import ElliotIPC
import ElliotModel
import ElliotStore
import MCP

/// Reads the board.
///
/// Falls back to a read-only snapshot of the database when Elliot is down, and
/// labels the answer `offline-db` rather than passing a snapshot off as the
/// live board.
struct ListCardsTool: BoardTool {
    var tool: Tool {
        Tool(
            name: "board_list_cards",
            description: """
                List Elliot board cards. Optionally filter by repository \
                (owner/name) and by column (backlog, todo, inProgress, inReview, done). \
                Returns each card's issue and pull-request numbers when it has them.
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
                    "limit": .object(["type": .string("integer"), "default": .int(100)]),
                ]),
            ]),
            annotations: .init(title: "List board cards", readOnlyHint: true)
        )
    }

    func call(_ args: [String: Value], bridge: AppBridge) async throws -> CallTool.Result {
        let repo = args["repo"]?.stringValue
        let column = args["column"]?.stringValue.flatMap(Column.init(rawValue:))
        let limit = args["limit"]?.intValue ?? 100

        switch bridge.read(.listCards(repo: repo, column: column, limit: limit)) {
        case .live(let response):
            return .render(response) { payload in
                guard case .cards(let cards) = payload else { return nil }
                return ["cards": .encoding(cards), "source": .string("live")]
            }
        case .offline(let store):
            let repos = try await store.repos()
            let match = repo.flatMap { name in
                repos.first { $0.nameWithOwner == name || $0.path == name }
            }
            let cards = try await store.cards(repoID: match?.id, column: column).prefix(limit)
            let dtos = cards.map { card in
                CardDTO(
                    card: card,
                    repoName: repos.first { $0.id == card.repoID }?.nameWithOwner ?? "?"
                )
            }
            return .ok([
                "cards": .encoding(Array(dtos)),
                // Say plainly that this is a snapshot, not the live board.
                "source": .string("offline-db"),
                "note": .string("Elliot is not running; this is a snapshot of its database."),
            ])
        }
    }
}
