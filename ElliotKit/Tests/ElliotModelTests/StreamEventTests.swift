import Foundation
import Testing

@testable import ElliotModel

private func decode(_ line: String) -> StreamEvent? {
    StreamEventDecoder.decode(line: Data(line.utf8))
}

private func decodeAll(_ line: String) -> [StreamEvent] {
    StreamEventDecoder.decodeAll(line: Data(line.utf8))
}

@Suite("stream-json decoding")
struct StreamEventTests {

    @Test("The init event exposes what the session can dispatch")
    func systemInit() throws {
        let event = decode(#"""
        {"type":"system","subtype":"init","session_id":"abc","cwd":"/repo","model":"claude-opus-5",\#
        "permissionMode":"bypassPermissions","tools":["Bash","Edit"],\#
        "slash_commands":["ai-migration-kit:create-issue","ai-migration-kit:merge-pr"],\#
        "claude_code_version":"2.1.221","mcp_servers":[{"name":"elliot","status":"connected"}]}
        """#)
        guard case .systemInit(let info) = try #require(event) else {
            Issue.record("expected systemInit, got \(String(describing: event))")
            return
        }
        #expect(info.sessionID == "abc")
        #expect(info.cwd == "/repo")
        #expect(info.slashCommands.contains("ai-migration-kit:create-issue"))
        #expect(info.tools == ["Bash", "Edit"])
        #expect(info.claudeCodeVersion == "2.1.221")
        #expect(info.mcpServers.first?.name == "elliot")
    }

    @Test("A successful result is clean")
    func successResult() throws {
        let event = decode(#"""
        {"type":"result","subtype":"success","is_error":false,"num_turns":7,"duration_ms":1234,\#
        "result":"Filed #47","total_cost_usd":0.42,"session_id":"abc","stop_reason":null,\#
        "terminal_reason":"completed","permission_denials":[]}
        """#)
        guard case .result(let result) = try #require(event) else {
            Issue.record("expected result, got \(String(describing: event))")
            return
        }
        #expect(result.isClean)
        #expect(result.text == "Filed #47")
        #expect(result.numTurns == 7)
        #expect(result.totalCostUSD == 0.42)
        #expect(!result.hitABudgetCeiling)
    }

    @Test("A success carrying permission denials is NOT clean")
    func denialsDefeatSuccess() throws {
        // The whole point of this check: the agent treats a refusal as a tool
        // error and often works around it, so the run still ends "success".
        let event = decode(#"""
        {"type":"result","subtype":"success","is_error":false,"num_turns":3,"result":"done",\#
        "total_cost_usd":0.1,"session_id":"abc","permission_denials":[\#
        {"tool_name":"Bash","tool_use_id":"tu_1","tool_input":{"command":"git push"}}]}
        """#)
        guard case .result(let result) = try #require(event) else {
            Issue.record("expected result")
            return
        }
        #expect(!result.isError)
        #expect(!result.isClean)
        #expect(result.permissionDenials.map(\.toolName) == ["Bash"])
    }

    @Test("Hitting a configured ceiling is distinguished from a crash")
    func maxTurnsIsNotACrash() throws {
        let event = decode(#"""
        {"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":40,\#
        "result":"","total_cost_usd":1.0,"session_id":"abc","permission_denials":[],\#
        "errors":["Reached maximum number of turns (40)"]}
        """#)
        guard case .result(let result) = try #require(event) else {
            Issue.record("expected result")
            return
        }
        #expect(result.hitABudgetCeiling)
        #expect(result.errors == ["Reached maximum number of turns (40)"])
    }

    @Test("A result with no terminal_reason decodes — a local command bypassed the loop")
    func missingTerminalReason() throws {
        let event = decode(#"""
        {"type":"result","subtype":"success","is_error":false,"num_turns":0,"result":"ok",\#
        "total_cost_usd":0,"session_id":"abc","permission_denials":[]}
        """#)
        guard case .result(let result) = try #require(event) else {
            Issue.record("expected result")
            return
        }
        #expect(result.terminalReason == nil)
        #expect(result.isClean)
    }

    @Test("Assistant text and tool calls are surfaced for the run log")
    func assistantBlocks() throws {
        let text = decode(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Working"}]}}"#)
        #expect(text == .assistantText("Working"))

        let tool = decode(#"""
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_1","name":"Bash",\#
        "input":{"command":"gh issue create"}}]}}
        """#)
        guard case .assistantToolUse(let name, let id, let preview) = try #require(tool) else {
            Issue.record("expected tool use")
            return
        }
        #expect(name == "Bash")
        #expect(id == "tu_1")
        #expect(preview.contains("gh issue create"))
    }

    @Test("A tool result reports its own failure flag")
    func toolResultBlock() throws {
        let event = decode(#"""
        {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_1",\#
        "is_error":true,"content":"permission denied"}]}}
        """#)
        guard case .toolResult(let id, let isError, let preview) = try #require(event) else {
            Issue.record("expected tool result")
            return
        }
        #expect(id == "tu_1")
        #expect(isError)
        #expect(preview == "permission denied")
    }

    @Test("Partial message deltas become text")
    func partialDelta() {
        let event = decode(#"""
        {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta",\#
        "text":"Hel"}},"session_id":"abc"}
        """#)
        #expect(event == .partial(text: "Hel"))
    }

    // MARK: - Every block of a line, not just the first

    @Test("An assistant turn carrying prose AND a tool call yields both, in source order")
    func textAndToolUseInOneTurn() throws {
        // The reason decodeAll exists: `decode` stops at the first block, so the
        // tool call below is silently thrown away — a row that never appears.
        let line = #"""
        {"type":"assistant","message":{"content":[{"type":"text","text":"Filing it now"},\#
        {"type":"tool_use","id":"tu_1","name":"Bash","input":{"command":"gh issue create"}}]}}
        """#
        let events = decodeAll(line)
        #expect(events.count == 2)

        #expect(events.first == .assistantText("Filing it now"))
        guard case .assistantToolUse(let name, let id, let preview) = try #require(events.last) else {
            Issue.record("expected the second block to be a tool use, got \(String(describing: events.last))")
            return
        }
        #expect(name == "Bash")
        #expect(id == "tu_1")
        #expect(preview.contains("gh issue create"))

        // decode stays the one-event entry point: exactly the first of them.
        #expect(decode(line) == events.first)
    }

    @Test("A turn with several tool calls yields one event per call")
    func severalToolUsesInOneTurn() {
        let events = decodeAll(#"""
        {"type":"assistant","message":{"content":[\#
        {"type":"tool_use","id":"tu_1","name":"Read","input":{"file_path":"a.swift"}},\#
        {"type":"tool_use","id":"tu_2","name":"Read","input":{"file_path":"b.swift"}},\#
        {"type":"tool_use","id":"tu_3","name":"Bash","input":{"command":"swift test"}}]}}
        """#)
        #expect(events.count == 3)
        let ids = events.compactMap { event -> String? in
            guard case .assistantToolUse(_, let id, _) = event else { return nil }
            return id
        }
        #expect(ids == ["tu_1", "tu_2", "tu_3"])
    }

    @Test("A user turn with two tool_result blocks yields two events")
    func severalToolResultsInOneTurn() {
        let events = decodeAll(#"""
        {"type":"user","message":{"content":[\#
        {"type":"tool_result","tool_use_id":"tu_1","is_error":false,"content":"ok"},\#
        {"type":"tool_result","tool_use_id":"tu_2","is_error":true,"content":"permission denied"}]}}
        """#)
        #expect(events.count == 2)
        #expect(events.first == .toolResult(toolUseID: "tu_1", isError: false, preview: "ok"))
        #expect(events.last == .toolResult(toolUseID: "tu_2", isError: true, preview: "permission denied"))
    }

    @Test("An empty text block is skipped, and skipping it does not swallow its neighbours")
    func emptyTextBlockSkipped() {
        let events = decodeAll(#"""
        {"type":"assistant","message":{"content":[{"type":"text","text":""},\#
        {"type":"thinking","thinking":"…"},\#
        {"type":"text","text":"Done"}]}}
        """#)
        #expect(events == [.assistantText("Done")])
    }

    // MARK: - The decoder must never throw and never drop

    @Test("An unrecognised type is kept rather than discarded")
    func unknownType() throws {
        let event = decode(#"{"type":"some_future_event","payload":{"a":1}}"#)
        guard case .unknown(let type, _) = try #require(event) else {
            Issue.record("expected unknown")
            return
        }
        #expect(type == "some_future_event")
    }

    @Test("A brand-new system subtype is kept with its subtype")
    func unknownSystemSubtype() throws {
        let event = decode(#"{"type":"system","subtype":"quantum_entanglement","session_id":"abc"}"#)
        guard case .system(let subtype, _) = try #require(event) else {
            Issue.record("expected system")
            return
        }
        #expect(subtype == "quantum_entanglement")
    }

    @Test("Garbage is reported, not thrown", arguments: [
        "not json at all",
        "{",
        "[1,2,3]",
        #"{"no_type":true}"#,
        "null",
    ])
    func garbageIsReported(line: String) throws {
        guard case .malformed = try #require(decode(line)) else {
            Issue.record("expected malformed for \(line)")
            return
        }
    }

    @Test("Blank lines are skipped", arguments: ["", "\n", "   \n", "\r\n"])
    func blankLinesSkipped(line: String) {
        #expect(decode(line) == nil)
    }

    @Test("decodeAll keeps every totality guarantee decode has", arguments: ["", "\n", "   \n", "\r\n"])
    func decodeAllIsBlankOnBlankLines(line: String) {
        #expect(decodeAll(line).isEmpty)
        #expect(decode(line) == nil)
    }

    @Test("Garbage is exactly one malformed event, not a list of them", arguments: [
        "not json at all",
        "{",
        "[1,2,3]",
        #"{"no_type":true}"#,
        "null",
    ])
    func garbageIsOneMalformed(line: String) throws {
        let events = decodeAll(line)
        #expect(events.count == 1)
        guard case .malformed = try #require(events.first) else {
            Issue.record("expected malformed for \(line), got \(String(describing: events.first))")
            return
        }
        #expect(decode(line) == events.first)
    }

    @Test("An unreadable line stays exactly one event", arguments: [
        #"{"type":"some_future_event","payload":{"a":1}}"#,
        // A message whose content is not an array of blocks: nothing to walk.
        #"{"type":"assistant","message":{"content":"just a string"}}"#,
        // A content array carrying no block this decoder understands.
        #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"…"}]}}"#,
    ])
    func unreadableLinesStayOneUnknown(line: String) throws {
        let events = decodeAll(line)
        #expect(events.count == 1)
        guard case .unknown = try #require(events.first) else {
            Issue.record("expected unknown for \(line), got \(String(describing: events.first))")
            return
        }
        #expect(decode(line) == events.first)
    }

    @Test("Trailing newlines do not defeat decoding", arguments: ["", "\n", "\r\n"])
    func trailingNewlineTolerated(suffix: String) throws {
        let event = decode(#"{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}"# + suffix)
        #expect(event == .assistantText("hi"))
    }

    @Test("A very large line decodes without truncation")
    func largeLine() throws {
        let big = String(repeating: "x", count: 512_000)
        let event = decode(#"{"type":"assistant","message":{"content":[{"type":"text","text":"\#(big)"}]}}"#)
        guard case .assistantText(let text) = try #require(event) else {
            Issue.record("expected text")
            return
        }
        #expect(text.count == 512_000)
    }

    @Test("Tool input previews are single-line and bounded")
    func previewsAreBounded() {
        let long = String(repeating: "a", count: 500)
        let preview = StreamEventDecoder.preview(of: "line1\nline2 " + long)
        #expect(!preview.contains("\n"))
        #expect(preview.count <= 201)
        #expect(preview.hasSuffix("…"))
    }
}
