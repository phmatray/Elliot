import Foundation
import Testing

@testable import ElliotModel

private let then = Date(timeIntervalSince1970: 1_700_000_000)

@Suite("What a verdict admits")
struct StandardVerdictTests {

    private let violation = Violation(
        summary: "No .editorconfig at the root", expected: "an .editorconfig",
        actual: "absent", fixHint: nil)

    @Test("Only a violation files a card")
    func onlyViolationFilesACard() {
        #expect(StandardVerdict.violating(violation).producesCard)
        #expect(!StandardVerdict.compliant(detail: "present").producesCard)
        #expect(!StandardVerdict.notApplicable(.fork).producesCard)
        #expect(!StandardVerdict.unmeasured(.rateLimited).producesCard)
    }

    /// A ratio must never be inflated by a failure to look.
    @Test("Unmeasured and not-applicable stay out of the denominator")
    func denominatorExcludesNonMeasurements() {
        #expect(StandardVerdict.compliant(detail: "").countsInDenominator)
        #expect(StandardVerdict.violating(violation).countsInDenominator)
        #expect(!StandardVerdict.unmeasured(.rateLimited).countsInDenominator)
        #expect(!StandardVerdict.notApplicable(.fork).countsInDenominator)
    }

    /// A verdict rests on several observations of different ages. Its age is the
    /// OLDEST of them: reporting the youngest is how a verdict resting on a
    /// day-old workflow reads as two minutes fresh.
    @Test("A finding's observation lag is that of its oldest input")
    func lagIsTheOldestInput() {
        let f = StandardFinding(
            id: "phmatray/Foo#ciJudgeable", nameWithOwner: "phmatray/Foo",
            standard: .ciJudgeable, verdict: .compliant(detail: "ci.yml"),
            evidence: [],
            provenances: [
                Provenance(command: "gh api …/contents", observedAt: then.addingTimeInterval(-120)),
                Provenance(command: "gh api …/trees", observedAt: then.addingTimeInterval(-86_000)),
            ],
            assessedAt: then)
        #expect(f.observationLag == 86_000)
    }

    /// The primary key overwrites only when a new measurement lands. If
    /// measurement stops — an expired token, a repository skipped every pass —
    /// August's row survives and must not read as current in November.
    @Test("A verdict's own staleness is measured from when it was assessed")
    func stalenessFromAssessment() {
        let f = StandardFinding(
            id: "x", nameWithOwner: "phmatray/Foo", standard: .topics,
            verdict: .compliant(detail: ""), evidence: [],
            provenances: [Provenance(command: "gh", observedAt: then)], assessedAt: then)
        #expect(f.staleness(at: then.addingTimeInterval(90 * 86_400)) == 90 * 86_400)
    }
}
