import Foundation
import Testing

@testable import ElliotModel

/// The one rule that says whether an unattended agent may start against a
/// repository.
///
/// Pure, so every caller consults the same answer: `AnalysisService`, the
/// appraisal, and `AnalysisRefusal` — which renders it for the toolbar's tooltip
/// and the analysis panel's footer, and adds the remedy the sentence names.
///
/// ⚠️ **The two sentences are the ones that shipped, verbatim.**
/// `Consequence.reason(.repoDisabled)` now reads `.repoDisabled.sentence` and
/// `AnalysisRefusal` reads both, so `AnalysisSessionTests` and
/// `AnalysisRefusalTests` compare against this file's strings without having been
/// edited. Rewording one here changes what four screens say.
@Suite("Unattended start — the refusal")
struct UnattendedStartRefusalTests {

    private func repo(enabled: Bool = true, persisted: PreflightState? = nil) -> Repo {
        Repo(
            path: "/tmp/r", nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot", isEnabled: enabled, preflight: persisted
        )
    }

    // MARK: - The rule

    @Test("A switched-on repository whose checks pass is not refused")
    func healthyIsAllowed() {
        #expect(UnattendedStartRefusal.refusal(repo: repo(), preflight: .passing) == nil)
    }

    @Test("A repository switched off is refused, whatever Preflight says")
    func disabledIsRefused() {
        for state in PreflightState.allCases {
            #expect(
                UnattendedStartRefusal.refusal(repo: repo(enabled: false), preflight: state)
                    == .repoDisabled)
        }
    }

    @Test("A repository whose Preflight is failing is refused")
    func failingIsRefused() {
        #expect(
            UnattendedStartRefusal.refusal(repo: repo(), preflight: .failing) == .preflightBlocked)
    }

    /// ⛔ The order is load-bearing, and it is the same order `evaluateMove`
    /// applies to a move (`.repoDisabled` before `.repoBlocked`). A repository can
    /// be both, and switching one on is a switch the reader threw — offering the
    /// diagnosis first sends someone hunting a finding when the answer is a toggle
    /// they turned off themselves.
    @Test("Switched off outranks failing, so the sentence names the switch not the check")
    func disabledOutranksFailing() {
        let refusal = UnattendedStartRefusal.refusal(
            repo: repo(enabled: false), preflight: .failing)

        #expect(refusal == .repoDisabled)
        #expect(refusal != .preflightBlocked)
    }

    /// ⚠️ **The decision this rule is most likely to be asked to change, so it is
    /// a named case with a named test rather than a value falling out of a
    /// two-valued answer.**
    ///
    /// `notChecked` does not refuse, deliberately: `evaluateMove` lets it through
    /// for reasons `PreflightState` writes out — blocking would freeze the board
    /// for the first seconds of every launch, and permanently whenever a
    /// rate-limited `gh label list` stops the sweep finishing. Refusing here
    /// would also silently change the shipped analysis gate.
    ///
    /// The point of the case is that changing that is a deliberate edit to this
    /// assertion rather than an accident of `contains { $0.status == .fail }`
    /// answering `false` on an empty array — which is the defect
    /// `PreflightState` and `PreflightReading` exist to have removed.
    @Test("Nobody has looked yet is not a refusal")
    func notCheckedDoesNotRefuse() {
        #expect(UnattendedStartRefusal.refusal(repo: repo(), preflight: .notChecked) == nil)
    }

    /// A negative needs its positive witness: a fourth `PreflightState` added
    /// without an answer here would otherwise be covered by nothing.
    @Test("Every preflight state has a stated answer, and only failing refuses")
    func everyStateIsAnswered() {
        let answers: [(PreflightState, UnattendedStartRefusal?)] = [
            (.notChecked, nil),
            (.passing, nil),
            (.failing, .preflightBlocked),
        ]

        #expect(
            Set(answers.map(\.0)) == Set(PreflightState.allCases),
            """
            PreflightState has a case this suite says nothing about. Whether an unattended agent \
            may start in it is then decided by whichever branch happens to catch it.
            """)

        for (state, expected) in answers {
            #expect(UnattendedStartRefusal.refusal(repo: repo(), preflight: state) == expected)
        }
    }

    /// ⛔ **The state is a parameter, and it wins over `Repo.preflight`.**
    ///
    /// The persisted column is what the board is gated on, because a badge may
    /// show a reading from a minute ago. A service that has *just* swept holds a
    /// fresher answer than the row it loaded, and an unattended start is the one
    /// caller that should be judged on the fresher one. Reading
    /// `repo.preflightVerdict` inside the rule would make that impossible to
    /// express while still compiling.
    @Test("The verdict passed in decides, not the one persisted on the row")
    func theParameterIsTheAuthority() {
        #expect(
            UnattendedStartRefusal.refusal(repo: repo(persisted: .failing), preflight: .passing)
                == nil)
        #expect(
            UnattendedStartRefusal.refusal(repo: repo(persisted: .passing), preflight: .failing)
                == .preflightBlocked)
    }

    // MARK: - What it says

    @Test("Every case has a sentence, and the two name different places to go")
    func everyCaseSpeaks() {
        let sentences = [
            UnattendedStartRefusal.repoDisabled.sentence,
            UnattendedStartRefusal.preflightBlocked.sentence,
        ]

        #expect(sentences.allSatisfy { !$0.isEmpty })
        #expect(Set(sentences).count == sentences.count)
        #expect(sentences.allSatisfy { $0.contains("Preflight") })
    }

    /// The strings themselves, because four screens read them and two suites in
    /// `ElliotAppKitTests` compare against them without importing this file.
    @Test("The two sentences are the ones that shipped")
    func theSentencesAreUnchanged() {
        #expect(
            UnattendedStartRefusal.repoDisabled.sentence
                == "This repository is switched off in Preflight.")
        #expect(
            UnattendedStartRefusal.preflightBlocked.sentence
                == "A Preflight check is failing for this repository — fix it there first.")
    }
}
