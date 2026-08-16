import ElliotModel
import ElliotProcess
import Testing

@testable import ElliotEngine

/// The one fold from a finished ACP turn to a `RunState`, driven directly.
///
/// `RunScheduler.state(for:cancelRequested:)` is `static` and pure precisely so this suite exists:
/// what a finished run *amounts to* is a rule, and a rule reachable only through a real spawn is a
/// rule nothing can drive over its whole input space.
@Suite("Non-execution fold")
struct NonExecutionFoldTests {
    static func outcome(_ kinds: [NonExecutionKind], denials: [String] = []) -> AgentRunOutcome {
        AgentRunOutcome(
            exitCode: 0,
            summary: TurnSummary(
                stopReason: "end_turn", denials: denials, nonExecutionKinds: kinds,
                isError: false),
            agentSessionID: "sess-1", stderr: "")
    }

    @Test("permission-rule makes a run completedWithDenials")
    func permissionRuleIsADenial() {
        #expect(RunScheduler.state(
            for: Self.outcome([.permissionRule], denials: ["Bash"]), cancelRequested: false)
            == .completedWithDenials)
    }

    /// ⛔ The regression this whole rule exists to prevent. Elliot cancels runs by design, and a
    /// cancelled run's in-flight tool calls carry `interrupted` or `cancelled`. Folding on the
    /// bare *presence* of a `nonExecutionKind` — the design's first frozen rule, corrected —
    /// would mark every cancelled run as one that "was refused a tool and quietly worked around
    /// the gap".
    @Test("interrupted, cancelled and user-rejected are not denials")
    func theThreeNonDenials() {
        for kind in [NonExecutionKind.interrupted, .cancelled, .userRejected] {
            #expect(RunScheduler.state(for: Self.outcome([kind]), cancelRequested: false)
                == .succeeded)
        }
    }

    @Test("an unrecognised kind is not defaulted to a denial")
    func unknownKindsAreNotDenials() {
        #expect(RunScheduler.state(
            for: Self.outcome([NonExecutionKind("shipped-next-tuesday")]), cancelRequested: false)
            == .succeeded)
    }

    @Test("a stop reason of cancelled is a cancelled run")
    func stopReasonDrivesCancellation() {
        let outcome = AgentRunOutcome(
            exitCode: 0,
            summary: TurnSummary(stopReason: "cancelled", isError: false),
            agentSessionID: "sess-1", stderr: "")
        #expect(RunScheduler.state(for: outcome, cancelRequested: true) == .cancelled)
    }

    /// Task 11's brake, from the engine side — the half `ACPRunnerTests` cannot assert, because
    /// `ElliotProcessTests` does not depend on `ElliotEngine` (`Package.swift:194-196`).
    ///
    /// ⛔ `state(for:)` tests `stopReason == "cancelled"` **before** `isError`, and the brake
    /// reaches the cancel path — so if Task 11's override ever stops outranking the agent's
    /// answer, a run stopped for crossing its spend ceiling reads as though a person pressed
    /// Cancel, on a card whose run cost more than it was allowed to.
    @Test("a braked run is a failure, not a cancellation")
    func aBrakedRunIsAFailure() {
        let outcome = AgentRunOutcome(
            exitCode: 0,
            summary: TurnSummary(stopReason: "elliot/max_budget", isError: true),
            agentSessionID: "sess-1", stderr: "")
        #expect(RunScheduler.state(for: outcome, cancelRequested: false) == .failed)
    }

    /// The SIGKILL backstop fired before the agent answered — Elliot asked, the agent never
    /// got to say. Elliot's own knowledge decides, because the exit code cannot: a killed
    /// adapter and a crashed one look identical from outside.
    @Test("a cancel Elliot asked for is cancelled even with no summary at all")
    func aRequestedCancelWithNoAnswer() {
        let outcome = AgentRunOutcome(
            exitCode: 143, summary: nil, agentSessionID: nil, stderr: "")
        #expect(RunScheduler.state(for: outcome, cancelRequested: true) == .cancelled)
        #expect(RunScheduler.state(for: outcome, cancelRequested: false) == .failed)
    }
}
