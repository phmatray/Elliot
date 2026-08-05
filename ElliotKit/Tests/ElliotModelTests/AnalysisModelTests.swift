import Foundation
import Testing

@testable import ElliotModel

@Suite("Analysis model")
struct AnalysisModelTests {

    @Test("Every angle carries a briefing that says what to leave alone", arguments: AnalysisAngle.allCases)
    func everyAngleIsBriefed(angle: AnalysisAngle) {
        #expect(!angle.title.isEmpty)
        #expect(!angle.symbol.isEmpty)
        // Without the second half every lens drifts back into generic review.
        #expect(angle.briefing.count > 120)
        #expect(angle.briefing.lowercased().contains("leave"))
    }

    @Test("Angle titles and symbols are distinct")
    func anglesAreDistinguishable() {
        #expect(Set(AnalysisAngle.allCases.map(\.title)).count == AnalysisAngle.allCases.count)
        #expect(Set(AnalysisAngle.allCases.map(\.symbol)).count == AnalysisAngle.allCases.count)
    }

    @Test("An unrecognised effort degrades rather than dropping the story", arguments: [
        ("small", Effort.small), ("MEDIUM", .medium), (" large ", .large),
        ("XL", .medium), ("", .medium), ("trivial", .medium),
    ])
    func effortParsing(raw: String, expected: Effort) {
        #expect(Effort.parse(raw) == expected)
    }

    @Test("Evidence splits on the trailing line number only", arguments: [
        ("Sources/A.swift:42", "Sources/A.swift", 42 as Int?),
        ("Sources/A.swift", "Sources/A.swift", nil),
        ("  Sources/A.swift:7  ", "Sources/A.swift", 7),
        // A colon that is not a line number belongs to the path.
        ("Sources/A.swift:notaline", "Sources/A.swift:notaline", nil),
        ("a:b:12", "a:b", 12),
    ])
    func evidenceParsing(raw: String, path: String, line: Int?) throws {
        let parsed = try #require(Evidence.parse(raw))
        #expect(parsed.path == path)
        #expect(parsed.line == line)
    }

    @Test("Evidence with no path at all is not evidence", arguments: ["", "   ", ":42"])
    func emptyEvidenceIsRejected(raw: String) {
        #expect(Evidence.parse(raw) == nil)
    }

    @Test("A proposal carries the story type the board already speaks")
    func proposalHoldsAUserStory() {
        let proposal = StoryProposal(
            analysisID: UUID(), runID: UUID(), repoID: UUID(), angle: .quickWins,
            title: "Add --json to the preflight CLI",
            story: UserStory(
                role: "developer", want: "preflight output as JSON",
                benefit: "I can gate CI on it", acceptanceCriteria: ["exit code reflects failures"]
            ),
            rationale: "The checks already exist; only the rendering is human-only.",
            evidence: [Evidence(path: "Sources/ElliotEngine/PreflightService.swift", line: 12, exists: true)],
            effort: .small,
            createdAt: Date()
        )
        #expect(proposal.status == .proposed)
        #expect(proposal.story.isComplete)
        #expect(proposal.story.narrative.hasPrefix("As a developer, I want"))
    }

    @Test("A duplicate hint says what it collided with")
    func duplicateHintLabels() {
        #expect(DuplicateHint.issue(number: 12, title: "Idle leak").label.contains("#12"))
        #expect(DuplicateHint.card(id: UUID(), title: "Dark mode").label.contains("Dark mode"))
    }
}
