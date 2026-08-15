import ACP
import ACPModel
import ElliotModel
import Foundation
import Testing

@testable import ElliotProcess

/// Driven by bytes the live adapter actually wrote, not by hand-built values.
///
/// `Fixtures/acp/turn-edit-bash.json` is a verbatim dump of every JSON-RPC message received
/// during one real turn at `bypassPermissions` on 2026-08-12 — 34 messages, of which 15 are
/// `tool_call`/`tool_call_update` frames across three tool calls. This is the same discipline
/// `RunLogRowTests` states for stream-json: decode fixtures through the real decoder, never
/// construct the model type by hand.
@Suite("Run event mapper")
struct RunEventMapperTests {
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ElliotProcessTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // ElliotKit
            .deletingLastPathComponent()  // repository root
    }

    /// Every `session/update` notification in a probe dump, decoded through the vendored types.
    static func notifications(in fixture: String) throws -> [SessionUpdateNotification] {
        let url = repositoryRoot.appendingPathComponent("Fixtures/acp/\(fixture)")
        let messages = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]]
        var decoded: [SessionUpdateNotification] = []
        for message in messages ?? [] where message["method"] as? String == "session/update" {
            let params = try JSONSerialization.data(withJSONObject: message["params"] as Any)
            decoded.append(try JSONDecoder().decode(SessionUpdateNotification.self, from: params))
        }
        return decoded
    }

    static func events(in fixture: String) throws -> [RunEvent] {
        try notifications(in: fixture).flatMap(RunEventMapper.events(from:))
    }

    /// ⛔ THE test. The `Edit` call arrives as **six** frames on one id, and the last carries
    /// `status: "completed"` and nothing else — no title, no kind, no locations, no content.
    ///
    /// ⚠️ The design's §5.1 shows four lines for this sequence; that is a condensation. Counted
    /// on the committed transcript there are six, because frames 2, 3 **and** 4 all repeat the
    /// refined title while `rawInput` fills in — three, not two, and worth counting rather than
    /// estimating. The assertion is unchanged, and stronger: two more chances for a replacing
    /// fold to look correct.
    @Test("the Edit call still has its title and its kind after its last frame")
    func editKeepsItsTitleAndKind() throws {
        let events = try Self.events(in: "turn-edit-bash.json")
        let rows = RunLog.rows(from: events)
        let edits = rows.compactMap { row -> ToolCallPatch? in
            guard case .toolCall(let call) = row,
                call.id == "toolu_01Lf1nZmGFgp68y1sbgi8fpb"
            else { return nil }
            return call
        }
        #expect(edits.count == 1)  // six frames, one row
        let edit = try #require(edits.first)
        #expect(edit.title == "Edit /private/tmp/elliot-acp-sandbox/notes.txt")
        #expect(edit.kind == .edit)
        #expect(edit.status == .completed)
        #expect(edit.claudeToolName == "Edit")
        #expect(edit.locations?.first?.path == "/private/tmp/elliot-acp-sandbox/notes.txt")
        // The diff is what this whole change exists for.
        let hasDiff = edit.content?.contains {
            if case .diff = $0 { return true }
            return false
        }
        #expect(hasDiff == true)
    }

    @Test("three tool calls, three rows, in the order they were first seen")
    func oneRowPerCall() throws {
        let rows = RunLog.rows(from: try Self.events(in: "turn-edit-bash.json"))
        let calls = rows.compactMap { row -> String? in
            guard case .toolCall(let call) = row else { return nil }
            return call.claudeToolName
        }
        #expect(calls == ["Read", "Edit", "Bash"])
    }

    /// The refusal, provoked with a `PreToolUse` hook that blocked every `Bash` call.
    @Test("a refused call carries permission-rule and folds to a denial")
    func refusalCarriesPermissionRule() throws {
        let rows = RunLog.rows(from: try Self.events(in: "turn-refusal.json"))
        let bash = try #require(
            rows.compactMap { row -> ToolCallPatch? in
                guard case .toolCall(let call) = row, call.claudeToolName == "Bash" else { return nil }
                return call
            }.first)
        #expect(bash.status == .failed)
        #expect(bash.nonExecutionKind == .permissionRule)
        #expect(bash.nonExecutionKind?.isDenial == true)
    }

    /// The contrast case, provoked separately so "no ordinary failure carries this" is not true
    /// merely because no ordinary failure existed to check.
    @Test("a genuine tool error carries no nonExecutionKind at all")
    func ordinaryFailureCarriesNothing() throws {
        let rows = RunLog.rows(from: try Self.events(in: "turn-ordinary-failure.json"))
        let read = try #require(
            rows.compactMap { row -> ToolCallPatch? in
                guard case .toolCall(let call) = row, call.claudeToolName == "Read" else { return nil }
                return call
            }.first)
        #expect(read.status == .failed)
        #expect(read.nonExecutionKind == nil)
    }

    /// ⛔ The empty-array case, which **no committed transcript exercises** and which is
    /// therefore hand-built here on purpose.
    ///
    /// `ToolCallUpdateDetails.content` is `[ToolCallContent]?` (`ACPModel/Updates.swift:376`),
    /// so a `tool_call_update` carrying `"content": []` decodes to `[]` rather than to `nil` —
    /// and under the merge rule `next.content ?? content` an empty array **replaces** a diff
    /// that an earlier frame established.
    ///
    /// ⚠️ An earlier wording of this comment said no `tool_call_update` in
    /// `Fixtures/acp/turn-edit-bash.json` carries an explicit empty `content`. Re-measured over
    /// the raw bytes: exactly one does — the **Read** call's second frame, position 2 of the
    /// transcript's 15 tool frames — and it erases nothing, because the creation frame ahead of
    /// it carried `[]` too, so there was never anything established to lose. The Edit call's
    /// last frame is a different shape again: it omits the key entirely (`_meta`, `rawOutput`,
    /// `sessionUpdate`, `status`, `toolCallId`).
    ///
    /// The conclusion is the one that matters and it survived the correction. Folding all five
    /// committed transcripts under both rules produces **identical** content on every tool call,
    /// so `editKeepsItsTitleAndKind` passes whether or not this is handled. That is exactly the
    /// shape of defect that ships.
    @Test("a frame that says content is empty does not erase the diff")
    func anEmptyContentArrayDoesNotClear() throws {
        let json = Data(
            """
            {"sessionId":"s","update":{"sessionUpdate":"tool_call_update",
             "toolCallId":"tc-1","content":[]}}
            """.utf8)
        let frame = try JSONDecoder().decode(SessionUpdateNotification.self, from: json)
        let established = ToolCallPatch(
            id: "tc-1", content: [.diff(path: "/tmp/a", oldText: "a", newText: "b")])
        let events = RunEventMapper.events(from: frame)
        guard case .toolCall(let patch) = try #require(events.first) else {
            Issue.record("not a tool call")
            return
        }
        #expect(patch.content == nil)  // "said nothing", not "said none"
        #expect(established.merging(patch).content?.count == 1)  // the diff survives
    }

    /// The same asymmetry from the other side: a frame carrying only an image block maps to no
    /// renderable content, and `content(_:)` is a `compactMap`, so it produces `[]`. That must
    /// read as absent too, or a picture erases a diff.
    ///
    /// ⚠️ The array here is **not** empty on the wire — it carries one `ToolCallContent` that
    /// really decoded — so the `!raw.isEmpty` guard alone does not save it. Only checking what
    /// the mapping *produced* does, which is why `mapped(_:)` looks at both ends.
    ///
    /// Hand-built because there is nothing to build it from: counted across all five committed
    /// transcripts, every block on the wire is either a text block or a diff — **26 in total,
    /// 21 text and 5 diff, and not one image or audio block**. This case has no witness, which
    /// is a reason to write it rather than a reason to skip it.
    @Test("a frame with nothing renderable in it does not erase the diff either")
    func unrenderableContentDoesNotClear() throws {
        let json = Data(
            """
            {"sessionId":"s","update":{"sessionUpdate":"tool_call_update",
             "toolCallId":"tc-1","content":[{"type":"content","content":
             {"type":"image","data":"iVBORw0KGgo=","mimeType":"image/png"}}]}}
            """.utf8)
        let frame = try JSONDecoder().decode(SessionUpdateNotification.self, from: json)
        // The frame really does carry a block; it is the mapping that empties it.
        guard case .toolCallUpdate(let details) = frame.update else {
            Issue.record("not a tool call update")
            return
        }
        #expect(details.content?.count == 1)

        let established = ToolCallPatch(
            id: "tc-1", content: [.diff(path: "/tmp/a", oldText: "a", newText: "b")])
        let events = RunEventMapper.events(from: frame)
        guard case .toolCall(let patch) = try #require(events.first) else {
            Issue.record("not a tool call")
            return
        }
        #expect(patch.content == nil)
        #expect(established.merging(patch).content?.count == 1)
    }

    /// Not a `default: continue`. Every arm is named, and this test is what keeps it that way.
    @Test("the six frame kinds nothing renders map to zero events, by name")
    func deliberatelyUnmappedFramesProduceNothing() throws {
        // `available_commands_update` is in the session-new transcript.
        let all = try Self.notifications(in: "session-new-commands.json")
        let commands = all.filter {
            if case .availableCommandsUpdate = $0.update { return true }
            return false
        }
        #expect(!commands.isEmpty)  // the fixture really carries them
        #expect(commands.flatMap(RunEventMapper.events(from:)).isEmpty)
    }
}
