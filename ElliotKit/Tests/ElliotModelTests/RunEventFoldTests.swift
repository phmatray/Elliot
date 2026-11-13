import Foundation
import Testing

@testable import ElliotModel

/// The rule the whole event model rests on: in a `ToolCallPatch`, `nil` means **absent from
/// this frame**, never *cleared*.
///
/// ⚠️ These patches are hand-built, and that is a real limit: this pins the *rule*, not the
/// wire. `RunEventMapperTests.editKeepsItsTitleAndKind` (Task 4) drives the identical assertion
/// through frames the live adapter actually wrote, which is where a decoder that invented a
/// default would be caught. Both exist on purpose, and neither replaces the other.
@Suite("Run event fold")
struct RunEventFoldTests {
    @Test("a later frame that omits a field does not clear it")
    func mergingKeepsWhatALaterFrameOmits() {
        let created = ToolCallPatch(
            id: "tc-1", title: "Edit", kind: .edit, status: .pending, claudeToolName: "Edit")
        let refined = ToolCallPatch(
            id: "tc-1", title: "Edit /tmp/notes.txt",
            locations: [FileLocation(path: "/tmp/notes.txt")])
        let completed = ToolCallPatch(id: "tc-1", status: .completed)

        let merged = created.merging(refined).merging(completed)

        #expect(merged.title == "Edit /tmp/notes.txt")   // the refinement won
        #expect(merged.kind == .edit)                    // survived two frames that omitted it
        #expect(merged.status == .completed)             // the last frame that carried one
        #expect(merged.locations?.count == 1)
        #expect(merged.claudeToolName == "Edit")
    }

    @Test("merging refuses to fold two different tool calls together")
    func mergingIsKeyedOnID() {
        let a = ToolCallPatch(id: "tc-1", title: "Edit")
        let b = ToolCallPatch(id: "tc-2", status: .completed)
        // Two calls in flight at once is the ordinary case, and their frames interleave.
        // Folding one into the other would attribute an outcome to the wrong act.
        #expect(a.merging(b).status == nil)
        #expect(a.merging(b).id == "tc-1")
    }

    @Test("content replaces wholesale when present, and only then")
    func collectionsAreReplacedNotAppended() {
        let first = ToolCallPatch(id: "tc-1", content: [.text("one")])
        let second = ToolCallPatch(id: "tc-1", content: [.text("one"), .text("two")])
        let third = ToolCallPatch(id: "tc-1", status: .completed)
        // ACP resends the whole array each time it changes — measured on
        // Fixtures/acp/turn-edit-bash.json, where the Edit call's content goes from absent to a
        // one-element diff in a single frame. Appending would double it.
        #expect(first.merging(second).content?.count == 2)
        #expect(first.merging(second).merging(third).content?.count == 2)
    }

    @Test("only permission-rule is a denial")
    func nonExecutionKindFoldsByValue() {
        #expect(NonExecutionKind("permission-rule").isDenial)
        #expect(!NonExecutionKind("interrupted").isDenial)
        #expect(!NonExecutionKind("cancelled").isDenial)
        #expect(!NonExecutionKind("user-rejected").isDenial)
        // The adapter's own source calls this an open set with no enum check, so a value nobody
        // has seen is UNMEASURED. Defaulting it to a denial is provably wrong three times over
        // on the list above: Elliot cancels runs by design, and a cancelled run's in-flight
        // tool calls carry `interrupted` or `cancelled`.
        #expect(!NonExecutionKind("something-shipped-next-tuesday").isDenial)
        #expect(NonExecutionKind("something-shipped-next-tuesday").rawValue
            == "something-shipped-next-tuesday")
    }

    @Test("an unrecognised kind survives as itself, so the log can name it")
    func unrecognisedKindsRoundTrip() throws {
        let kind = NonExecutionKind("brand-new")
        let data = try JSONEncoder().encode(kind)
        // ⛔ The bare string is the assertion that matters, and round-trip identity alone does
        // not make it. Measured: delete `NonExecutionKind.init(from:)`/`encode(to:)` and this
        // suite still reports `6 tests in 1 suite passed`, because Swift's synthesized enum
        // `Codable` round-trips just as faithfully — into `{"unrecognised":{"_0":"brand-new"}}`.
        // The wire the adapter writes and every persisted log holds is `"brand-new"`, so this
        // line is what keeps the custom `Codable` load-bearing against a future "the synthesized
        // one is fine here" simplification.
        #expect(String(decoding: data, as: UTF8.self) == "\"brand-new\"")
        #expect(try JSONDecoder().decode(NonExecutionKind.self, from: data) == kind)
    }

    @Test("an unrecognised tool kind survives as itself too")
    func unrecognisedToolKindsRoundTrip() throws {
        let kind = ToolCallKind(rawValue: "teleport")
        #expect(kind == .unrecognised("teleport"))
        let data = try JSONEncoder().encode(kind)
        // Same reasoning as above, and the same measured weakness: identity holds either way.
        #expect(String(decoding: data, as: UTF8.self) == "\"teleport\"")
        #expect(try JSONDecoder().decode(ToolCallKind.self, from: data) == kind)
    }
}
