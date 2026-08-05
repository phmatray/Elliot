import ElliotIPC
import ElliotModel
import MCP

/// Adds a card to the backlog.
///
/// A write, so it is served only by the running app — never by writing to the
/// database directly.
struct CreateCardTool: BoardTool {
    var tool: Tool {
        Tool(
            name: "board_create_card",
            description: """
                Create a card in the Elliot backlog. The backlog holds user stories, so \
                prefer supplying role / want / benefit and acceptance criteria separately \
                rather than prose in `title`. Creating a card runs nothing on its own — \
                moving it to `todo` is what files a GitHub issue.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "repo": .object([
                        "type": .string("string"),
                        "description": .string("Repository as owner/name, or an absolute path."),
                    ]),
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("Short board label."),
                    ]),
                    "role": .object([
                        "type": .string("string"),
                        "description": .string("Who the story is for, e.g. \"developer\"."),
                    ]),
                    "want": .object([
                        "type": .string("string"),
                        "description": .string("The capability wanted, phrased as an action."),
                    ]),
                    "benefit": .object([
                        "type": .string("string"),
                        "description": .string("Why the capability is worth building."),
                    ]),
                    "acceptance_criteria": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                    "body": .object([
                        "type": .string("string"),
                        "description": .string("Free-text note, for a card that is not a story."),
                    ]),
                    "column": .object([
                        "type": .string("string"),
                        "enum": .array(Column.allCases.map { .string($0.rawValue) }),
                        "default": .string("backlog"),
                    ]),
                ]),
                "required": .array([.string("repo"), .string("title")]),
            ]),
            annotations: .init(title: "Create a card", readOnlyHint: false, destructiveHint: false)
        )
    }

    func call(_ args: [String: Value], bridge: AppBridge) async throws -> CallTool.Result {
        guard let repo = args["repo"]?.stringValue, let title = args["title"]?.stringValue else {
            return .failure(code: "bad_argument", message: "repo and title are required.")
        }
        let story: ElliotRequest.StoryInput? = {
            let role = args["role"]?.stringValue ?? ""
            let want = args["want"]?.stringValue ?? ""
            let benefit = args["benefit"]?.stringValue ?? ""
            guard !role.isEmpty || !want.isEmpty || !benefit.isEmpty else { return nil }
            return .init(
                role: role, want: want, benefit: benefit,
                acceptanceCriteria: args["acceptance_criteria"]?.arrayValue?
                    .compactMap(\.stringValue) ?? []
            )
        }()

        let response = bridge.write(.createCard(
            repo: repo,
            title: title,
            body: args["body"]?.stringValue ?? "",
            story: story,
            column: args["column"]?.stringValue.flatMap(Column.init(rawValue:)) ?? .backlog
        ))
        return .render(response) { payload in
            guard case .card(let card) = payload else { return nil }
            return ["card": .encoding(card)]
        }
    }
}
