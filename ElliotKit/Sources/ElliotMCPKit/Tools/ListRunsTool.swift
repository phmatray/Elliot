import ElliotIPC
import ElliotStore
import Foundation
import MCP

/// Follows the runs a move started. `board_move_card` returns as soon as a run
/// is queued, so this is the only way an agent learns how one ended.
///
/// It carries the whole `RunDTO` — `verifiedOutcome`, `exitCode`, `numTurns`,
/// `stderrPath`, `isTerminal` — and not a summary of it. A shortened run reads
/// as `state: succeeded` with nothing to contradict it, and `succeeded` is
/// compatible with having filed no issue and merged nothing.
struct ListRunsTool: BoardTool {
    var tool: Tool {
        Tool(
            name: "board_list_runs",
            description: """
                List skill runs, most recent first: state, verified outcome, exit code, \
                cost, and where the log is.

                Read `verifiedOutcome` — that is what `gh` established. `state: succeeded` \
                is compatible with `no_issue_created`, `not_merged` and `unverified`: the \
                agent finished cleanly and nothing was created or merged. `resultText` is \
                display text, not a fact, and must never be parsed for issue or \
                pull-request numbers. `resultSource` says whose words it is: `agent` is \
                the agent's own account of its work, `stderr` is what the process left \
                behind when it died before saying anything, and `elliot` is the board's \
                own sentence about a run it could not start or that a crash orphaned. \
                Do not quote it as the agent's without reading that field — and an \
                **absent** `resultSource` means the run finished before this was \
                recorded, not that the agent wrote it.

                `isTerminal: false` means the run is still going, and `pollAfterSeconds` \
                says how long to wait before looking again — but prefer board_await_run, \
                which waits server-side and answers the moment the run ends. Terminal \
                states: succeeded, completedWithDenials, failed, cancelled, timedOut. \
                `stalled` is **not** terminal: the run has emitted nothing for a while and \
                is still alive, and it is yours to decide whether to keep waiting or \
                board_cancel_run it.

                `logPath` is a file of NDJSON — one Claude Code stream-json event per line, \
                exactly as the CLI emitted it. The same content is readable as the resource \
                `elliot://run/{id}/log`. `stderrPath` is where the process's stderr went.

                An analysis run has no card. It carries `analysisID` and `angle` instead — \
                `bugs`, `quickWins`, `features`, `techDebt`, `tests` or `docsAndDX` — which is \
                what tells two readings of the same repository apart. Once it has finished it \
                also carries `analysisReport`: `source` says where the stories came from \
                (`artifact`, or `resultText` when they had to be recovered from the closing \
                message), `kept` and `dropped` say what survived and why the rest did not, and \
                `workingTreeChanged` is the git sentinel. Read that one carefully: `false` \
                means the repository was checked and untouched, and the field being **absent** \
                means it was never checked at all. An analysis has no business writing to a \
                repository, so "unchecked" is not "clean". `workingTreeDiff` carries \
                `git status --porcelain` when the tree did move.

                The answer is a page: `total`, `truncated` and `limit_capped_from` say \
                whether you are seeing everything.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "card_id": .object([
                        "type": .string("string"),
                        "description": .string("Only runs for this card. Omit for every card."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "default": .int(ElliotPaging.runLimitDefault),
                        "description": .string("Capped at \(ElliotPaging.runLimitMax)."),
                    ]),
                ]),
            ]),
            annotations: .init(
                title: "List runs",
                readOnlyHint: true,
                // The sharpest case for the rule: these rows carry `resultText`,
                // which an agent wrote, and `verifiedOutcome`, which came from
                // `gh`. Both were stored by the run that produced them — this
                // call fetches nothing, so the world it reads is closed.
                openWorldHint: false
            )
        )
    }

    func call(_ args: [String: Value], bridge: any BridgeProviding) async throws -> CallTool.Result {
        let cardID = try args.optionalUUID("card_id")
        // Unclamped on purpose, exactly as board_list_cards does it: the app is
        // what caps the page, and it is what reports having capped it.
        let requested = try args.limit() ?? 0

        // The card-not-found refusal — "this card has no runs" and "there is no
        // such card" are different answers, and only one of them means keep
        // waiting — is `OfflineResponder`'s now, in the same words the running
        // app uses. It was hand-thrown here, and it had to be taught to this
        // tool separately after being fixed one tool over.
        let outcome = await bridge.read(.listRuns(cardID: cardID, limit: requested))
        return try .render(outcome) { payload in
            guard case .runs(let page) = payload else { return nil }
            var fields = ToolOutput.pageFields(
                total: page.total, limit: page.limit,
                truncated: page.truncated, cappedFrom: page.limitCappedFrom
            )
            fields["runs"] = try Value.encoding(page.runs)
            ToolOutput.attachNote(&fields, ToolOutput.pageNote(
                shown: page.runs.count, total: page.total,
                truncated: page.truncated, limit: page.limit, cappedFrom: page.limitCappedFrom
            ))
            return fields
        }
    }
}
