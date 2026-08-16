import Foundation
import Testing

@testable import ElliotModel

private let lostSession = "5f1b2c3d-4e5f-6789-abcd-ef0123456789"

/// The terminal event a Claude Code run reports when the transcript it was
/// asked to fork is not there: it errors before the first turn.
private func sessionGoneResult(
    subtype: String = ResumeVerdict.sessionGoneSubtype,
    isError: Bool = true,
    numTurns: Int? = 0,
    errors: [String] = ["No conversation found with session ID: \(lostSession)"]
) -> RunResult {
    RunResult(
        subtype: subtype,
        isError: isError,
        text: "No conversation found with session ID: \(lostSession)",
        numTurns: numTurns,
        sessionID: lostSession,
        errors: errors
    )
}

@Suite("The resume verdict")
struct ResumeVerdictTests {

    /// Every conjunct is load-bearing, so every conjunct is dropped once. A
    /// predicate written on `numTurns` alone would call a credit failure, a
    /// max-turns stop and a local slash command "the session is gone" — and in
    /// PR4 each of those would spend a fresh relaunch on a run that will fail
    /// again for the same reason.
    @Test("Drop any one conjunct and the run counts as having run")
    func theFullPredicate() {
        let previous = UUID()
        #expect(ResumeVerdict.of(resumedFrom: previous, result: sessionGoneResult()) == .sessionGone)

        // A run that was never a resume cannot have lost a session.
        #expect(ResumeVerdict.of(resumedFrom: nil, result: sessionGoneResult()) == .ran)
        // No terminal result at all — an orphan, a crash — establishes nothing.
        #expect(ResumeVerdict.of(resumedFrom: previous, result: nil) == .ran)
        // Errored after doing work: a failure, not a missing transcript.
        #expect(ResumeVerdict.of(
            resumedFrom: previous, result: sessionGoneResult(numTurns: 3)) == .ran)
        // `num_turns` absent is not `num_turns: 0`.
        #expect(ResumeVerdict.of(
            resumedFrom: previous, result: sessionGoneResult(numTurns: nil)) == .ran)
        // Zero turns and no error is a local slash command, not a lost session.
        #expect(ResumeVerdict.of(
            resumedFrom: previous, result: sessionGoneResult(isError: false)) == .ran)
        // The same shape under another subtype is a different failure.
        #expect(ResumeVerdict.of(
            resumedFrom: previous, result: sessionGoneResult(subtype: "error_max_turns")) == .ran)
        // Zero turns, error, right subtype — and the CLI complaining about
        // something else entirely.
        #expect(ResumeVerdict.of(
            resumedFrom: previous,
            result: sessionGoneResult(errors: ["Credit balance is too low"])) == .ran)
        // Nothing said at all.
        #expect(ResumeVerdict.of(
            resumedFrom: previous, result: sessionGoneResult(errors: [])) == .ran)
    }

    @Test("The wording is matched by prefix, so the session id may follow it")
    func matchedByPrefix() {
        let previous = UUID()
        #expect(ResumeVerdict.of(
            resumedFrom: previous,
            result: sessionGoneResult(errors: ["No conversation found"])) == .sessionGone)
        // A prefix and not a substring: a sentence that merely quotes the CLI
        // is not the CLI refusing.
        #expect(ResumeVerdict.of(
            resumedFrom: previous,
            result: sessionGoneResult(errors: ["I saw: No conversation found"])) == .ran)
    }

    // MARK: - Under ACP

    @Test("a fork the agent refused is a gone session")
    func aRefusedForkIsSessionGone() {
        #expect(ResumeVerdict.of(resumedFrom: UUID(), sessionResumeFailed: true) == .sessionGone)
    }

    @Test("a run that was never a resume is never sessionGone, whatever else failed")
    func anUnresumedRunIsAlwaysRan() {
        #expect(ResumeVerdict.of(resumedFrom: nil, sessionResumeFailed: true) == .ran)
    }

    @Test("a resumed run that actually ran is ran, however badly it ended")
    func aResumedRunThatRanIsRan() {
        #expect(ResumeVerdict.of(resumedFrom: UUID(), sessionResumeFailed: false) == .ran)
    }
}
