import ElliotIPC
import Foundation
import MCP

/// Signals a run to stop, and reports how far the stop got rather than claiming
/// it is done.
///
/// Goes through `bridge.write` for two reasons, and the second is the one that
/// bites. Only the running app can signal a process — but it is also the only
/// thing that knows the run id is real: `board.cancel` refuses one that never
/// existed, and `.render` carries that refusal out with the app's own code.
/// Answered any other way, cancelling a run that does not exist would come back
/// as a plausible success, and the caller would stop watching a run that is
/// still going.
///
/// `cancelling` and `cancelled` are both real answers, so the note names the
/// state the run had actually reached instead of implying the process is gone.
struct CancelRunTool: BoardTool {
    var tool: Tool {
        Tool(
            name: "board_cancel_run",
            description: """
                Stop a run that is going nowhere. The run is signalled, not killed on the \
                spot: it passes through `cancelling` before `cancelled`, and the answer \
                tells you which of the two it had reached.

                Cancelling is destructive by nature. An implement-issue stopped halfway \
                leaves its branch and its worktree behind; a merge-pr stopped halfway may \
                already have merged. Read `verifiedOutcome` on the returned run to find out \
                what it managed to do before it was stopped, and expect to clean up by hand.

                The usual reason is a `stalled` run you are done waiting for. A run that is \
                already terminal is returned unchanged.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "run_id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("run_id")]),
            ]),
            annotations: .init(
                title: "Cancel a run",
                readOnlyHint: false,
                // Half-done work stays half-done.
                destructiveHint: true,
                idempotentHint: true,
                // The run it stops is mid-conversation with github.com.
                openWorldHint: true
            )
        )
    }

    func call(_ args: [String: Value], bridge: any BridgeProviding) async throws -> CallTool.Result {
        let id = try args.uuid("run_id")
        let response = await bridge.write(.cancelRun(id: id))
        return try .render(response) { payload in
            guard case .run(let run) = payload else { return nil }
            var fields: [String: Value] = ["run": try Value.encoding(run)]
            if !run.isTerminal {
                ToolOutput.attachNote(
                    &fields,
                    "Signalled, not stopped yet — the run is in \(run.state).",
                    "Call board_await_run to see where it lands."
                )
            }
            return fields
        }
    }
}
