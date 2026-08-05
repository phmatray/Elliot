import ElliotIPC
import ElliotModel
import MCP

/// Adds a card to the backlog.
///
/// A write is never served from the database. A card that appeared without the
/// rule engine seeing it is the bug this architecture exists to prevent, so
/// this goes over the socket or it fails — there is deliberately no offline
/// path here, unlike every read.
struct CreateCardTool: BoardTool {
    var tool: Tool {
        Tool(
            name: "board_create_card",
            description: """
                Create a card in the Elliot backlog. The backlog holds user stories, so \
                prefer supplying role / want / benefit and acceptance criteria separately \
                rather than prose in `title`. Creating a card runs nothing on its own — \
                moving it to `todo` is what files a GitHub issue.

                Pass `idempotency_key` — any stable string you can derive again from the \
                same idea — and a retry after a timeout returns the card you already made \
                instead of a second one. The answer says `already_existed: true` when that \
                happened. Without a key, two calls make two cards.

                The key is unique across the **whole board**, not per repository. Derive it \
                from the repository as well as the idea, or a sweep filing "add-license" in \
                twenty repositories will create one card and report the other nineteen as \
                already existing. Check the `repo` on the card that comes back.

                There is no delete. A card created with the wrong text is corrected with \
                board_update_card, and a card that turned out to be a bad idea is left in \
                the backlog.
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
                    "idempotency_key": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Stable key that makes this call safe to retry. Reusing it returns the existing card."
                        ),
                    ]),
                ]),
                "required": .array([.string("repo"), .string("title")]),
            ]),
            annotations: .init(
                title: "Create a card",
                readOnlyHint: false,
                // Adds a row and starts nothing.
                destructiveHint: false,
                // Only with an idempotency_key, and the caller chooses whether
                // to send one — so the honest static answer is "no".
                idempotentHint: false,
                openWorldHint: false
            )
        )
    }

    func call(_ args: [String: Value], bridge: any BridgeProviding) async throws -> CallTool.Result {
        guard let repo = args["repo"]?.stringValue, let title = args["title"]?.stringValue else {
            throw ToolFailure(code: "bad_argument", message: "repo and title are required.")
        }

        // `""` is what a client templating an optional field sends, and it means
        // "no key". Passed through it would be a key like any other, and since
        // the unique index counts an empty string as a value it would collide
        // with the next one. The board also normalises it; a bad argument should
        // not reach that far.
        let key = args["idempotency_key"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }

        let response = await bridge.write(.createCard(
            repo: repo,
            title: title,
            body: args["body"]?.stringValue ?? "",
            story: args.story(),
            column: try args.column("column") ?? .backlog,
            idempotencyKey: key
        ))
        return try .render(response) { payload in
            guard case .created(let created) = payload else { return nil }
            var fields: [String: Value] = [
                "card": try Value.encoding(created.card),
                "already_existed": .bool(created.alreadyExisted),
            ]
            if created.alreadyExisted {
                // The repository is named rather than left to be diffed out of
                // the card. A key reused across repositories answers with the
                // card it made in the *first* one, and a sweep that does not
                // notice reports nineteen no-ops as nineteen successes. Said
                // this way rather than as a comparison because `repo` may have
                // been given as a checkout path, and only the board knows that
                // the two name one repository.
                ToolOutput.attachNote(
                    &fields,
                    "A card with this idempotency_key already existed in \(created.card.repo); "
                        + "nothing was created. The key is unique board-wide, so check that is "
                        + "the repository you meant."
                )
            }
            return fields
        }
    }
}
