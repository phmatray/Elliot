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

    @Test("Exactly one of card or analysis owns a run")
    func aRunBelongsToOneThing() {
        let cardRun = SkillRun(
            cardID: UUID(), repoID: UUID(), kind: .createIssue, prompt: "x",
            cwd: "/tmp", logPath: "/tmp/a.ndjson", stderrPath: "/tmp/a.log", createdAt: Date()
        )
        #expect(cardRun.cardID != nil)
        #expect(cardRun.analysisID == nil)
        #expect(!cardRun.isAnalysis)

        let analysisRun = SkillRun(
            cardID: nil, repoID: UUID(), analysisID: UUID(), analysisAngle: .bugs,
            kind: .analyzeRepo, prompt: "x", cwd: "/tmp",
            logPath: "/tmp/b.ndjson", stderrPath: "/tmp/b.log", createdAt: Date()
        )
        #expect(analysisRun.cardID == nil)
        #expect(analysisRun.isAnalysis)
        #expect(analysisRun.analysisAngle == .bugs)
    }

    /// The raw values are written into SQLite — `analysis.angles` as JSON and
    /// `skillRun.analysisAngle` as a column — so renaming a case orphans every
    /// stored row that named it, silently and with no migration to notice.
    ///
    /// The one assertion here that does not come for free: `everyAngleIsBriefed`
    /// and `anglesAreDistinguishable` both take `arguments: allCases` and so
    /// cover a new case the moment it exists, but neither would notice a case
    /// being *renamed*.
    @Test("The persisted raw values are pinned, in board order")
    func rawValuesArePersistedContract() {
        #expect(AnalysisAngle.allCases.map(\.rawValue) == [
            "bugs", "quickWins", "features", "techDebt", "tests", "docsAndDX",
            "uxAndUI", "bestPractices",
        ])
    }

    @Test("The default method declares the three plugin skills and no analyze-repo step")
    func onlySkillsHaveCommands() throws {
        let kit = try #require(aiMigrationKitPack())
        #expect(kit.steps[.createIssue]?.command == "/ai-migration-kit:create-issue")
        #expect(kit.steps[.implementIssue]?.command == "/ai-migration-kit:implement-issue")
        #expect(kit.steps[.mergePR]?.command == "/ai-migration-kit:merge-pr")
        // There is no analyze-repo skill; that prompt is Elliot's own and is
        // built by `AnalysisPromptBuilder`, which never reaches a pack.
        #expect(kit.steps[.analyzeRepo] == nil)
    }
}
