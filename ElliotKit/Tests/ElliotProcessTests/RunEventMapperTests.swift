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

    /// One notification from a JSON literal, for the frame kinds and content blocks that **no**
    /// committed transcript carries.
    ///
    /// Hand-built in its *bytes*, never in its *values*: the literal still goes through the same
    /// vendored `JSONDecoder` the fixtures do, so a shape this repository has guessed wrong
    /// fails to decode here rather than passing as a model object nobody could have received.
    /// The census that says which kinds need this is in `text(of:)`'s doc comment and in the two
    /// silent-frame tests below.
    static func frame(_ json: String) throws -> SessionUpdateNotification {
        try JSONDecoder().decode(SessionUpdateNotification.self, from: Data(json.utf8))
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
        let frame = try Self.frame(
            """
            {"sessionId":"s","update":{"sessionUpdate":"tool_call_update",
             "toolCallId":"tc-1","content":[]}}
            """)
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
        let frame = try Self.frame(
            """
            {"sessionId":"s","update":{"sessionUpdate":"tool_call_update",
             "toolCallId":"tc-1","content":[{"type":"content","content":
             {"type":"image","data":"iVBORw0KGgo=","mimeType":"image/png"}}]}}
            """)
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

    // MARK: - The six arms that deliberately render nothing

    /// ⛔ Six of `SessionUpdate`'s thirteen arms return `[]` **by name**, and the mapper's own
    /// doc comment claims a test pins them. Until a review of this task that claim was false for
    /// five of the six: this test was called *"the six frame kinds nothing renders map to zero
    /// events"* and exercised **one**.
    ///
    /// Measured on a clean tree at `f0c0839`, before the fix: rewriting all five unpinned arms
    /// at once to emit events — `user_message_chunk` rendered as `.agentText`, which is Elliot's
    /// own prompt presented as the agent's prose and the exact harm that arm's comment names,
    /// plus junk `.plan` and `.modeChanged` events for the other four — left the **whole suite**
    /// green: `Test run with 2823 tests in 332 suites passed after 4.452 seconds`.
    ///
    /// ⚠️ And the gap was wider than "no fixture carries them", which is why the count was worth
    /// re-taking rather than inheriting. `session_info_update` **is** carried, four times across
    /// four transcripts, and it was unpinned too — because nothing in this file counts events,
    /// so extra ones simply pass through every `compactMap`. A fixture exercising a line is not
    /// a test asserting on it.
    ///
    /// The two kinds a transcript really carries are pinned from those bytes, here; the four it
    /// does not are pinned from hand-built bytes, below.
    @Test("the two silent frame kinds a transcript carries map to zero events")
    func silentFramesWithATranscriptProduceNothing() throws {
        let all =
            try Self.notifications(in: "session-new-commands.json")
            + Self.notifications(in: "turn-edit-bash.json")

        let commands = all.filter {
            if case .availableCommandsUpdate = $0.update { return true }
            return false
        }
        let sessionInfo = all.filter {
            if case .sessionInfoUpdate = $0.update { return true }
            return false
        }

        // The fixtures really carry both, so an empty filter cannot be mistaken for a pass.
        #expect(!commands.isEmpty)
        #expect(!sessionInfo.isEmpty)
        #expect(commands.flatMap(RunEventMapper.events(from:)).isEmpty)
        #expect(sessionInfo.flatMap(RunEventMapper.events(from:)).isEmpty)
    }

    /// The other four, hand-built because no committed transcript carries one — censused across
    /// all five: `available_commands_update`, `current_mode_update`, `usage_update`,
    /// `tool_call`, `tool_call_update`, `agent_message_chunk` and `session_info_update`, and
    /// nothing else.
    ///
    /// Each frame asserts which case it decoded to before asserting that the case renders
    /// nothing. Without that, a literal that quietly decoded to a *different* arm would report
    /// "zero events" about an arm this test never reached.
    @Test("the four silent frame kinds no transcript carries map to zero events")
    func silentFramesWithoutATranscriptProduceNothing() throws {
        let userMessage = try Self.frame(
            """
            {"sessionId":"s","update":{"sessionUpdate":"user_message_chunk",
             "content":{"type":"text","text":"Elliot wrote this prompt"}}}
            """)
        let configOption = try Self.frame(
            """
            {"sessionId":"s","update":{"sessionUpdate":"config_option_update","configOptions":
             [{"id":"thinking","name":"Thinking","type":"boolean","currentValue":true}]}}
            """)
        let planUpdate = try Self.frame(
            """
            {"sessionId":"s","update":{"sessionUpdate":"plan_update","plan":
             {"type":"markdown","planId":"plan-1","content":"# a draft"}}}
            """)
        let planRemoved = try Self.frame(
            """
            {"sessionId":"s","update":{"sessionUpdate":"plan_removed","planId":"plan-1"}}
            """)

        if case .userMessageChunk = userMessage.update {} else { Issue.record("not a user chunk") }
        if case .configOptionUpdate = configOption.update {} else { Issue.record("not a config") }
        if case .planUpdate = planUpdate.update {} else { Issue.record("not a plan update") }
        if case .planRemoved = planRemoved.update {} else { Issue.record("not a plan removal") }

        for frame in [userMessage, configOption, planUpdate, planRemoved] {
            #expect(RunEventMapper.events(from: frame).isEmpty)
        }
    }

    /// ⛔ The control the arm above needs to mean anything. `user_message_chunk` must render
    /// nothing **because Elliot wrote it**, not because its block was unrenderable — and the
    /// two are indistinguishable from an assertion that only ever sees zero.
    ///
    /// So the identical content block is sent twice, down two arms: as the user's chunk it
    /// produces nothing, as the agent's it produces exactly one `.agentText` carrying that text.
    /// Reverting `case .userMessageChunk` to render turns the first half red while the second
    /// half stays green, which is the shape that says the test is measuring the arm.
    @Test("the same block Elliot wrote renders nothing, and the agent's renders prose")
    func onlyTheAgentsHalfOfAChunkIsRendered() throws {
        let block = #"{"type":"text","text":"the very same words"}"#
        let mine = try Self.frame(
            """
            {"sessionId":"s","update":{"sessionUpdate":"user_message_chunk","content":\(block)}}
            """)
        let theirs = try Self.frame(
            """
            {"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":\(block)}}
            """)

        #expect(RunEventMapper.events(from: mine).isEmpty)
        #expect(RunEventMapper.events(from: theirs) == [.agentText("the very same words")])
    }

    // MARK: - The five content-block kinds

    /// ⛔ An embedded text resource is **prose**, and dropping it would be the silent drop this
    /// whole model exists to end.
    ///
    /// `text(of:)` was `if case .text(let text) = block` — a `default:` in all but syntax — so
    /// four of `ContentBlock`'s five cases fell through it, while its doc comment named two.
    /// One of the four, `.resource`, wraps an `EmbeddedResourceType` whose `.text` case carries
    /// a plain `String` (`ACPModel/Content.swift:220`): real, renderable text, discarded with no
    /// trace and — on a message chunk, where `text(of:) ?? []` is the whole mapping — without
    /// even an `.unreadable` row to show something had arrived.
    ///
    /// Hand-built: not one of the 53 content blocks across the five committed transcripts is
    /// anything but a text block.
    @Test("an embedded text resource is read as prose, on both the chunk and the tool arm")
    func anEmbeddedTextResourceIsRead() throws {
        let resource = """
            {"type":"resource","resource":{"type":"text","uri":"file:///tmp/notes.txt",
             "text":"what the resource actually said"}}
            """

        let chunk = try Self.frame(
            """
            {"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":\(resource)}}
            """)
        #expect(
            RunEventMapper.events(from: chunk) == [.agentText("what the resource actually said")])

        let call = try Self.frame(
            """
            {"sessionId":"s","update":{"sessionUpdate":"tool_call_update","toolCallId":"tc-1",
             "content":[{"type":"content","content":\(resource)}]}}
            """)
        guard case .toolCall(let patch) = try #require(RunEventMapper.events(from: call).first)
        else {
            Issue.record("not a tool call")
            return
        }
        #expect(patch.content == [.text("what the resource actually said")])
    }

    /// The other side of the same switch, decided by name rather than by omission: a picture, a
    /// sound, a link that carries no body, and a resource whose payload is base64 are all real
    /// absences. A `resource_link` is the interesting one — it has a `uri` and a `name`, so
    /// rendering it would mean *composing* a line out of two fields, which is a guess about an
    /// adapter that has never been measured emitting one.
    ///
    /// Each is checked on the chunk arm, where an absence costs the whole event, and the block
    /// is asserted to have decoded first so that "no event" cannot mean "no block".
    @Test("a picture, a sound, a bare link and a blob resource render nothing, by name")
    func theFourUnrenderableBlockKindsRenderNothing() throws {
        let blocks = [
            #"{"type":"image","data":"iVBORw0KGgo=","mimeType":"image/png"}"#,
            #"{"type":"audio","data":"UklGRiQ=","mimeType":"audio/wav"}"#,
            #"{"type":"resource_link","uri":"file:///tmp/notes.txt","name":"notes.txt"}"#,
            """
            {"type":"resource","resource":{"type":"blob","uri":"file:///tmp/a.bin",
             "blob":"aGVsbG8="}}
            """,
        ]
        for block in blocks {
            let chunk = try Self.frame(
                """
                {"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk",
                 "content":\(block)}}
                """)
            guard case .agentMessageChunk(let decoded) = chunk.update else {
                Issue.record("not an agent chunk: \(block)")
                continue
            }
            // It really is a block; it is the mapping that declines to show it.
            if case .text = decoded { Issue.record("decoded as text: \(block)") }
            #expect(RunEventMapper.events(from: chunk).isEmpty, "\(block)")
        }
    }
}
