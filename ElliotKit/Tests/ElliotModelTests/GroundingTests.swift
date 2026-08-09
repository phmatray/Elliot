import Foundation
import Testing

@testable import ElliotModel

private let then = Date(timeIntervalSince1970: 1_700_000_000)

private func cited(_ path: String, exists: Bool) -> Evidence {
    Evidence(path: path, line: 1, exists: exists)
}

@Suite("Grounding")
struct GroundingTests {

    /// The whole reason this is not a `Bool`. "Nobody ever cited a file" is a
    /// silence; "files were cited and are not there" is an admission. A boolean
    /// answers `false` to both and a reader cannot tell them apart.
    @Test("A silence and an admission are different answers")
    func silenceIsNotAnAdmission() {
        #expect(Grounding.of(evidence: []) == .notCited)
        #expect(Grounding.of(evidence: [cited("A.swift", exists: false)]) == .missing(count: 1))
        #expect(Grounding.of(evidence: [cited("A.swift", exists: true)]) == .grounded)
    }

    @Test("Missing counts only the citations that are not there")
    func missingCountsTheAbsentOnes() {
        let mixed = [
            cited("A.swift", exists: true),
            cited("B.swift", exists: false),
            cited("C.swift", exists: false),
        ]
        #expect(Grounding.of(evidence: mixed) == .missing(count: 2))
    }

    /// The codes travel to agents, so they are written out rather than derived
    /// from the case names — the rule `PRSign.code` and `CIState.code` already
    /// keep, and the reason `files_missing` is not `missing`.
    @Test("Every grounding has a stable code and a sentence")
    func codesAndSummaries() {
        #expect(Grounding.notCited.code == "not_cited")
        #expect(Grounding.grounded.code == "grounded")
        #expect(Grounding.missing(count: 3).code == "files_missing")

        #expect(Grounding.missing(count: 1).summary.contains("One"))
        #expect(Grounding.missing(count: 3).summary.contains("3"))
        for grounding: Grounding in [.notCited, .grounded, .missing(count: 1)] {
            #expect(grounding.summary.hasSuffix("."))
            #expect(grounding.summary.count > 20)
        }
    }

    /// One definition, two readers. `isGrounded` is read by the panel's seal
    /// and by the wire's `grounded` flag; if it kept its own `allSatisfy` the
    /// two would be free to drift apart the first time either is corrected.
    @Test("A proposal's grounding and its boolean say the same thing")
    func proposalAgreesWithItsGrounding() {
        func proposal(_ evidence: [Evidence]) -> StoryProposal {
            StoryProposal(
                analysisID: UUID(), runID: UUID(), repoID: UUID(),
                angle: .bugs, title: "Bound the await",
                story: UserStory(role: "maintainer", want: "a bounded wait", benefit: "no hangs"),
                evidence: evidence, createdAt: then
            )
        }

        #expect(proposal([cited("A.swift", exists: true)]).grounding == .grounded)
        #expect(proposal([cited("A.swift", exists: true)]).isGrounded)
        #expect(!proposal([]).isGrounded)
        #expect(!proposal([cited("A.swift", exists: false)]).isGrounded)
    }
}
