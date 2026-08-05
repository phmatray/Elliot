import ElliotIPC
import MCP

/// Corrects what a human wrote on a card — and nothing else.
///
/// A write, so it is served only by the running app: the board refuses this
/// once the card carries an issue number, and that refusal is a rule. Writing
/// the row from here would edit text that github.com is by then the record of,
/// with nothing to reconcile the two.
struct UpdateCardTool: BoardTool {
    var tool: Tool {
        Tool(
            name: "board_update_card",
            description: """
                Correct a card's label, note or story. This is the only way to fix a card \
                that was created with the wrong text — there is no delete, deliberately: a \
                card is the board's only link to an issue or pull request that exists on \
                github.com.

                Replaces the fields it is given rather than patching them, so send the whole \
                story, not the one line you want changed. Omitting `role` / `want` / \
                `benefit` entirely clears the story and leaves the card a plain note.

                Refused with `card_already_filed` once the card carries an issue number: \
                from that moment the GitHub issue is the record and it is edited there. That \
                refusal is permanent — it is not `read_only`, and retrying later will not \
                change it.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "card_id": .object(["type": .string("string")]),
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("Short board label. Required: it is a replacement, not a patch."),
                    ]),
                    "role": .object(["type": .string("string")]),
                    "want": .object(["type": .string("string")]),
                    "benefit": .object(["type": .string("string")]),
                    "acceptance_criteria": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                    "body": .object([
                        "type": .string("string"),
                        "description": .string("Free-text note. Omit to clear it."),
                    ]),
                ]),
                "required": .array([.string("card_id"), .string("title")]),
            ]),
            annotations: .init(
                title: "Correct a card",
                readOnlyHint: false,
                // Overwrites text that nothing keeps a copy of.
                destructiveHint: true,
                idempotentHint: true,
                openWorldHint: false
            )
        )
    }

    func call(_ args: [String: Value], bridge: any BridgeProviding) async throws -> CallTool.Result {
        let id = try args.uuid("card_id")
        guard let title = args["title"]?.stringValue else {
            throw ToolFailure(
                code: "bad_argument",
                message: "title is required: this replaces the card's text rather than patching it."
            )
        }
        let response = await bridge.write(.updateCard(
            id: id,
            title: title,
            body: args["body"]?.stringValue ?? "",
            story: args.story()
        ))
        return try .render(response) { payload in
            guard case .card(let card) = payload else { return nil }
            return ["card": try Value.encoding(card)]
        }
    }
}
