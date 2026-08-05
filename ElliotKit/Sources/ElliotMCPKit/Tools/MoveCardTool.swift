import ElliotIPC
import ElliotModel
import Foundation
import MCP

/// Moves a card, which is how every run in Elliot starts.
///
/// The transition itself decides what runs — the rule engine in the app owns
/// that table, and this tool never second-guesses it. That is also why there is
/// one tool and not two: a separate "merge" tool would be a second way to reach
/// the same act, and the second way is the one nobody keeps in step with the
/// rules.
///
/// A write is never served from the database. Moving a card without firing its
/// rule is the bug this architecture exists to prevent, so this goes over the
/// socket or it fails.
struct MoveCardTool: BoardTool {
    var tool: Tool {
        Tool(
            name: "board_move_card",
            description: """
                Move a card to another column. This is how work is driven, and it is not \
                bookkeeping: three transitions spawn an unattended agent inside the \
                repository's working tree.

                  backlog → todo        files a GitHub issue (create-issue)
                  todo → inProgress     writes code on a new branch and opens a pull \
                request (implement-issue)
                  inReview → done       squash-merges that pull request, deletes its branch, \
                tears down its worktree, and files every entry of `follow_ups` as a new \
                issue (merge-pr)

                Blast radius: those agents run as `claude --permission-mode \
                bypassPermissions` in most repositories — they edit files, commit, push and \
                call `gh` without asking anyone, in the real checkout on this machine. \
                inReview → done writes to the repository's default branch on github.com and \
                nothing here can undo it. Check board_list_repos for the permission mode \
                before you move a card in a repository you have not driven before.

                Returns as soon as the run is queued, not when it finishes; runs take \
                minutes to tens of minutes. Follow it with board_await_run using the \
                returned `run_id`, and judge the result by `verifiedOutcome`, never by the \
                agent's prose. Every other transition simply repositions the card and runs \
                nothing.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "card_id": .object(["type": .string("string")]),
                    "to": .object([
                        "type": .string("string"),
                        "enum": .array(Column.allCases.map { .string($0.rawValue) }),
                    ]),
                    "follow_ups": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string(
                            "Follow-up work to file as issues after a merge. Omit for none."
                        ),
                    ]),
                ]),
                "required": .array([.string("card_id"), .string("to")]),
            ]),
            annotations: .init(
                title: "Move a card",
                readOnlyHint: false,
                // Merges, deletes branches and removes worktrees. Understating
                // this was the single worst thing about version 1 of this tool.
                destructiveHint: true,
                // A second call is a second move, and can be a second run.
                idempotentHint: false,
                // Reaches github.com.
                openWorldHint: true
            )
        )
    }

    func call(_ args: [String: Value], bridge: any BridgeProviding) async throws -> CallTool.Result {
        let id = try args.uuid("card_id")
        guard let to = try args.column("to") else {
            throw ToolFailure(
                code: "bad_argument",
                message: "`to` is required, and must be one of: "
                    + "\(Column.allCases.map(\.rawValue).joined(separator: ", "))."
            )
        }
        // An omitted list means "no follow-ups", not "ask me" — the UI is the
        // only caller that gets to be asked.
        let followUps = args["follow_ups"]?.arrayValue?.compactMap(\.stringValue) ?? []

        let response = await bridge.write(.moveCard(id: id, to: to, followUps: followUps))
        return try .render(response) { payload in
            guard case .moved(let move) = payload else { return nil }
            var fields: [String: Value] = [
                "card_id": .string(move.cardID.uuidString),
                "from": .string(move.from),
                "to": .string(move.to),
                "summary": .string(move.summary),
            ]
            if let runID = move.runID { fields["run_id"] = .string(runID.uuidString) }
            if let triggered = move.triggered { fields["triggered"] = .string(triggered) }
            if let poll = move.pollAfterSeconds { fields["poll_after_seconds"] = .int(poll) }
            ToolOutput.attachNote(&fields, move.runID.map { runID in
                "The run is queued, not finished. Call board_await_run with run_id "
                    + "\(runID.uuidString) and read verifiedOutcome when it returns."
            })
            return fields
        }
    }
}
