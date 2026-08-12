import ACP
import ACPModel
import Foundation
import Testing

/// `_meta.claudeCode.toolName` is how a card keeps rendering `Read` / `Edit` / `Bash` after the
/// wire changes. A decoder that drops unknown `_meta` would make the vendored library unusable
/// here regardless of how cleanly it compiles, so this is pinned rather than assumed.
@Suite("ACP model decoding")
struct ACPModelDecodingTests {
    @Test("a tool call keeps its Claude-specific _meta, nested values included")
    func toolCallMetaSurvives() throws {
        let json = """
        {"sessionId":"sess-1",
         "update":{"sessionUpdate":"tool_call","toolCallId":"tc-1","title":"Read File",
                   "kind":"read","status":"pending","content":[],
                   "_meta":{"claudeCode":{"toolName":"Read","nested":{"deep":true}}}}}
        """
        let note = try JSONDecoder().decode(
            SessionUpdateNotification.self, from: Data(json.utf8)
        )
        guard case .toolCall(let call) = note.update else {
            Issue.record("expected a tool_call update")
            return
        }
        let claudeCode = call._meta?["claudeCode"]?.value as? [String: any Sendable]
        #expect(claudeCode?["toolName"] as? String == "Read")
        #expect((claudeCode?["nested"] as? [String: any Sendable])?["deep"] as? Bool == true)
    }

    @Test("_meta survives an encode/decode round trip")
    func metaSurvivesRoundTrip() throws {
        let json = """
        {"sessionId":"sess-1",
         "update":{"sessionUpdate":"tool_call","toolCallId":"tc-1","title":"Read File",
                   "kind":"read","status":"pending","content":[],
                   "_meta":{"claudeCode":{"toolName":"Read"}}}}
        """
        let once = try JSONDecoder().decode(
            SessionUpdateNotification.self, from: Data(json.utf8)
        )
        let twice = try JSONDecoder().decode(
            SessionUpdateNotification.self, from: JSONEncoder().encode(once)
        )
        guard case .toolCall(let call) = twice.update else {
            Issue.record("expected a tool_call update")
            return
        }
        let claudeCode = call._meta?["claudeCode"]?.value as? [String: any Sendable]
        #expect(claudeCode?["toolName"] as? String == "Read")
    }
}
