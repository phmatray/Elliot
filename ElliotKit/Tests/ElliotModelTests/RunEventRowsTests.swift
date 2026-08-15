import Foundation
import Testing

@testable import ElliotModel

@Suite("Run event rows")
struct RunEventRowsTests {
    static func patch(
        _ id: String, title: String? = nil, kind: ToolCallKind? = nil,
        status: ToolCallStatus? = nil, content: [ToolContent]? = nil,
        nonExecutionKind: NonExecutionKind? = nil
    ) -> RunEvent {
        .toolCall(ToolCallPatch(
            id: id, title: title, kind: kind, status: status, content: content,
            nonExecutionKind: nonExecutionKind))
    }

    @Test("frames for one id fold into one row that keeps everything it was told")
    func framesFoldIntoOneRow() {
        let rows = RunLog.rows(from: [
            Self.patch("tc-1", title: "Edit", kind: .edit, status: .pending),
            Self.patch("tc-1", title: "Edit /tmp/notes.txt"),
            Self.patch("tc-1", content: [.diff(path: "/tmp/notes.txt", oldText: "a", newText: "b")]),
            Self.patch("tc-1", status: .completed),
        ])
        #expect(rows.count == 1)
        guard case .toolCall(let call) = rows[0] else { Issue.record("not a tool call"); return }
        #expect(call.title == "Edit /tmp/notes.txt")
        #expect(call.kind == .edit)
        #expect(call.status == .completed)
        #expect(call.content?.count == 1)
    }

    @Test("two calls in flight at once keep their own rows, in first-seen order")
    func interleavedCallsStaySeparate() {
        let rows = RunLog.rows(from: [
            Self.patch("tc-1", title: "Read", kind: .read, status: .pending),
            Self.patch("tc-2", title: "Bash", kind: .execute, status: .pending),
            Self.patch("tc-2", status: .completed),
            Self.patch("tc-1", status: .failed),
        ])
        #expect(rows.count == 2)
        guard case .toolCall(let first) = rows[0], case .toolCall(let second) = rows[1] else {
            Issue.record("expected two tool calls"); return
        }
        #expect(first.id == "tc-1")
        #expect(first.status == .failed)
        #expect(second.id == "tc-2")
        #expect(second.status == .completed)
    }

    /// ⛔ The frame order here is deliberately the one the committed fixture **cannot** produce.
    /// On `Fixtures/acp/turn-edit-bash.json` there are ten `usage_update` frames and the cost
    /// appears on the tenth, which is also the last — so against real bytes "the last frame" and
    /// "the last frame that carried a cost" give the same answer, and no test driven by that
    /// fixture can tell the two rules apart. Putting the costless frame **last** is what makes
    /// this test discriminate.
    @Test("the turn carries the latest context figures and the last cost it was told")
    func usageIsCarriedNotRendered() {
        let rows = RunLog.rows(
            from: [
                .usage(RunUsage(used: 33021, size: 1_000_000, costUSD: nil)),
                .usage(RunUsage(used: 37355, size: 1_000_000, costUSD: 0.2855775)),
                .usage(RunUsage(used: 37400, size: 1_000_000, costUSD: nil)),
            ],
            summary: TurnSummary(stopReason: "end_turn", isError: false))
        #expect(rows.count == 1)
        guard case .turnEnded(let summary) = rows[0] else { Issue.record("no summary"); return }
        #expect(summary.usage?.used == 37400)          // the latest figures
        #expect(summary.usage?.costUSD == 0.2855775)   // the last cost anyone reported
    }

    @Test("a turn nobody costed reports no cost, never zero")
    func absentCostIsNotZero() {
        let rows = RunLog.rows(
            from: [.usage(RunUsage(used: 100, size: 1_000_000, costUSD: nil))],
            summary: TurnSummary(stopReason: "end_turn", isError: false))
        guard case .turnEnded(let summary) = rows[0] else { Issue.record("no summary"); return }
        #expect(summary.usage?.costUSD == nil)
    }

    @Test("errors filter keeps a failed call, a denial and an unclean turn")
    func errorsFilter() {
        let rows = RunLog.rows(from: [
            Self.patch("tc-1", title: "Read", status: .completed),
            Self.patch("tc-2", title: "Bash", status: .failed,
                       nonExecutionKind: NonExecutionKind("permission-rule")),
            .agentThought("thinking"),
        ], summary: TurnSummary(stopReason: "end_turn", isError: false))
        let errors = RunLog.filter(rows, by: .errors)
        #expect(errors.count == 1)
        guard case .toolCall(let call) = errors[0] else { Issue.record("wrong row"); return }
        #expect(call.id == "tc-2")
    }
}
