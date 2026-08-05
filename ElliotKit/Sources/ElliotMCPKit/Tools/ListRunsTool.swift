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
                the agent's own account of its work; it is display text, not a fact, and \
                must never be parsed for issue or pull-request numbers.

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
            annotations: .init(title: "List runs", readOnlyHint: true, openWorldHint: false)
        )
    }

    func call(_ args: [String: Value], bridge: any BridgeProviding) async throws -> CallTool.Result {
        let cardID = try args.optionalUUID("card_id")
        // Unclamped on purpose, exactly as board_list_cards does it: the app is
        // what caps the page, and it is what reports having capped it.
        let requested = try args.limit() ?? 0

        switch await bridge.read(.listRuns(cardID: cardID, limit: requested)) {
        case .live(let response):
            return try .render(response) { payload in
                guard case .runs(let page) = payload else { return nil }
                var fields = ToolOutput.pageFields(
                    total: page.total, limit: page.limit,
                    truncated: page.truncated, cappedFrom: page.limitCappedFrom
                )
                fields["runs"] = try Value.encoding(page.runs)
                fields["source"] = .string("live")
                ToolOutput.attachNote(&fields, ToolOutput.pageNote(
                    shown: page.runs.count, total: page.total,
                    truncated: page.truncated, limit: page.limit, cappedFrom: page.limitCappedFrom
                ))
                return fields
            }

        case .offline(let store, let reason):
            // The same refusal the running app makes, for the same reason: "this
            // card has no runs" and "there is no such card" are different
            // answers, and only one of them means keep waiting. Filtering on an
            // id that matches nothing answers the first when the truth is the
            // second — which is finding 3 again, one tool over.
            if let cardID, try await store.card(id: cardID) == nil {
                throw ToolFailure(
                    code: ElliotErrorCode.cardNotFound.rawValue,
                    message: "No card with id \(cardID).",
                    hint: "board_list_cards lists the cards this board holds."
                )
            }
            let (limit, cappedFrom) = ElliotPaging.clamp(
                requested,
                default: ElliotPaging.runLimitDefault,
                max: ElliotPaging.runLimitMax
            )
            let runs = try await store.runs(cardID: cardID, limit: limit).map { RunDTO(run: $0) }
            let total = try await store.runCount(cardID: cardID)
            let page = RunPage(runs: runs, total: total, limit: limit, limitCappedFrom: cappedFrom)
            var fields = ToolOutput.pageFields(
                total: page.total, limit: page.limit,
                truncated: page.truncated, cappedFrom: page.limitCappedFrom
            )
            fields["runs"] = try Value.encoding(page.runs)
            fields["source"] = .string("offline-db")
            ToolOutput.attachNote(
                &fields,
                ToolOutput.offlineNote(reason),
                ToolOutput.pageNote(
                    shown: page.runs.count, total: page.total,
                    truncated: page.truncated, limit: page.limit, cappedFrom: page.limitCappedFrom
                )
            )
            return try .ok(fields)
        }
    }
}
