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

    /// ⚠️ **What this pins, precisely — and what it does not.**
    ///
    /// It pins the *engine* half: given a summary whose `denials` list is empty, `state(for:)`
    /// answers `.succeeded` however many `nonExecutionKinds` came along for the ride. That is worth
    /// pinning, because it is what keeps a recorded-but-not-folded kind from leaking into the
    /// verdict later.
    ///
    /// ⛔ It does **not** pin the by-value fold itself, and an earlier version of this comment
    /// claimed it did — "the regression this whole rule exists to prevent". The final whole-branch
    /// review measured otherwise: `kinds` is inert here. `state(for:)` reads `stopReason`,
    /// `isError` and `isClean`, and `isClean` is `!isError && denials.isEmpty` — so
    /// `nonExecutionKinds` drives no decision at any layer, and these three cases pass because
    /// `denials` **defaults to empty**, not because the kinds are non-denials. Switching the real
    /// fold to by-presence left this suite green.
    ///
    /// The fold is pinned where it is applied:
    /// `ACPRunnerTests.theDenialFoldIsByValueNotByPresence`, driven end to end through
    /// `Fixtures/acp/fake-nonexecution-kinds.json`, which carries all four kinds so that by-value
    /// and by-presence disagree by three. This suite and that one are two halves; neither is the
    /// other's substitute.
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
