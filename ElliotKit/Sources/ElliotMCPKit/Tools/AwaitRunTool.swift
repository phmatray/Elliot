import ElliotIPC
import Foundation
import MCP

/// Holds one call open until a run ends, so following a move costs a round trip
/// rather than a poll loop.
///
/// A long poll, not a blocking call: when the window closes before the run
/// does, the run is returned as it stands with a note saying so. Rendering that
/// as an error would be a lie the agent acts on — it would read a run that is
/// still going as a run that broke, and stop following work it started.
///
/// Goes through `bridge.write`, not `read`, even though it changes nothing. A
/// read may be answered from the read-only snapshot, and a snapshot cannot
/// advance: the wait would spend its whole window re-reading one frozen row and
/// then report the run as unfinished forever.
///
/// Nothing here sizes the socket. `ElliotRequest.socketTimeout` derives it from
/// the request — the window plus `ElliotTimeouts.awaitGrace` — precisely so no
/// call site can get the two out of step. Reversed, the client hangs up on an
/// answer already on its way and a still-running run reads as a dead app.
struct AwaitRunTool: BoardTool {
    var tool: Tool {
        Tool(
            name: "board_await_run",
            description: """
                Wait for a run to reach a terminal state, then return it. This is the right \
                way to follow a move: the wait happens server-side, so one call replaces a \
                poll loop that would otherwise burn a round trip every few seconds for as \
                long as the run takes.

                `timeout_seconds` defaults to \(ElliotTimeouts.awaitDefaultSeconds) and is \
                capped at \(ElliotTimeouts.awaitMaxSeconds); asking for more is clamped, not \
                refused. **A timeout is not an error.** You get the run in whatever state it \
                is in, with `isTerminal: false` and a `pollAfterSeconds` hint — call again \
                to keep waiting. So check `isTerminal` before you believe the run is over, \
                and then read `verifiedOutcome` for what it actually achieved.

                Changes nothing, but it does need Elliot running, and starts it if it is not.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "run_id": .object([
                        "type": .string("string"),
                        "description": .string("Run UUID, as returned by board_move_card."),
                    ]),
                    "timeout_seconds": .object([
                        "type": .string("integer"),
                        "default": .int(ElliotTimeouts.awaitDefaultSeconds),
                        "description": .string(
                            "How long to hold the wait. Capped at \(ElliotTimeouts.awaitMaxSeconds)."
                        ),
                    ]),
                ]),
                "required": .array([.string("run_id")]),
            ]),
            annotations: .init(
                title: "Wait for a run",
                // It writes nothing, but it is not free: it holds a connection,
                // and it will launch Elliot if Elliot is down.
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        )
    }

    func call(_ args: [String: Value], bridge: any BridgeProviding) async throws -> CallTool.Result {
        let id = try args.uuid("run_id")
        let seconds = try args.integer("timeout_seconds") ?? ElliotTimeouts.awaitDefaultSeconds
        // Refused rather than clamped, for the reason `limit` is: downstream a
        // non-positive wait becomes a returns-immediately poll, so the caller
        // that computed `deadline - now` and went negative would be told the
        // run is not finished, over and over, with nothing naming the argument.
        guard seconds > 0 else {
            throw ToolFailure(
                code: "bad_argument",
                message: "timeout_seconds must be at least 1."
            )
        }

        let response = await bridge.write(.awaitRun(id: id, timeoutSeconds: seconds))
        return try .render(response) { payload in
            guard case .run(let run) = payload else { return nil }
            var fields: [String: Value] = ["run": try Value.encoding(run)]
            if !run.isTerminal {
                ToolOutput.attachNote(
                    &fields,
                    "The wait window closed before the run did. This is not a failure:",
                    "call board_await_run again with the same run_id to keep waiting."
                )
            }
            return fields
        }
    }
}
