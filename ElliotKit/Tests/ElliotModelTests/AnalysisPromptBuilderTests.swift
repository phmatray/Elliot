import Testing

@testable import ElliotModel

@Suite("Analysis prompt")
struct AnalysisPromptBuilderTests {

    private func build(
        angle: AnalysisAngle = .bugs,
        titles: [String] = [],
        maxStories: Int = 8,
        extra: String = "",
        githubAvailable: Bool = true
    ) -> String {
        AnalysisPromptBuilder.prompt(
            angle: angle,
            repoNameWithOwner: "phmatray/Elliot",
            outputPath: "/tmp/elliot/analyses/A/B/stories.json",
            existingTitles: titles,
            maxStories: maxStories,
            extraInstructions: extra,
            githubTitlesAvailable: githubAvailable
        )
    }

    /// The invariant the whole harvest depends on, in the same spirit as
    /// "the first digit run of an implement-issue prompt is the issue number".
    @Test("The prompt announces exactly one output path, and it is absolute",
          arguments: AnalysisAngle.allCases)
    func exactlyOneAbsoluteOutputPath(angle: AnalysisAngle) throws {
        let prompt = build(angle: angle, titles: ["Dark mode", "Run log"], extra: "focus on ElliotProcess")
        let occurrences = prompt.components(separatedBy: AnalysisPromptBuilder.outputMarker).count - 1
        #expect(occurrences == 1)

        let path = try #require(AnalysisPromptBuilder.outputPath(in: prompt))
        #expect(path == "/tmp/elliot/analyses/A/B/stories.json")
        #expect(path.hasPrefix("/"))
    }

    @Test("The angle's briefing is what makes one prompt differ from another")
    func theBriefingIsCarried() {
        for angle in AnalysisAngle.allCases {
            #expect(build(angle: angle).contains(angle.briefing))
        }
        #expect(build(angle: .bugs) != build(angle: .tests))
    }

    @Test("The prompt names the repository and the cap")
    func promptCarriesItsSubject() {
        let prompt = build(maxStories: 5)
        #expect(prompt.contains("phmatray/Elliot"))
        #expect(prompt.contains("5"))
        #expect(prompt.lowercased().contains("do not modify"))
        #expect(prompt.contains("\"acceptance_criteria\""))
    }

    @Test("Existing titles are listed, newest first, and capped")
    func existingTitlesAreCapped() {
        let titles = (1...200).map { "Existing story \($0)" }
        let prompt = build(titles: titles)
        #expect(prompt.contains("Existing story 1"))
        #expect(!prompt.contains("Existing story 100"))
        let listed = prompt
            .split(separator: "\n")
            .filter { $0.hasPrefix("- Existing story ") }
        #expect(listed.count == AnalysisPromptBuilder.maxExistingTitles)
    }

    @Test("With no titles at all the section is left out rather than left empty")
    func noTitlesNoSection() {
        #expect(!build(titles: []).contains("do not propose these again"))
    }

    @Test("When gh could not be reached the prompt says so instead of implying completeness")
    func partialDeduplicationIsAdmitted() {
        let prompt = build(titles: ["Dark mode"], githubAvailable: false)
        #expect(prompt.contains("could not be reached"))
    }

    @Test("Extra instructions are passed through verbatim")
    func extraInstructionsSurvive() {
        let extra = "Ignore the SwiftUI layer.\nLook hard at ElliotIPC."
        #expect(build(extra: extra).contains(extra))
    }

    @Test("An empty extra-instructions field adds nothing")
    func emptyExtraAddsNothing() {
        #expect(!build(extra: "   ").contains("Additional instructions"))
    }

    @Test("A prompt with no marker has no output path")
    func noMarkerNoPath() {
        #expect(AnalysisPromptBuilder.outputPath(in: "nothing here") == nil)
    }

    @Test("Free-text fields containing the marker are sanitized to preserve the invariant")
    func markerInFreeTextIsSanitized() {
        // The marker appearing in existingTitles (from GitHub issue titles or board cards)
        // or extraInstructions (from user input) must not duplicate the marker in the prompt.
        let titles = [
            "Crash when \(AnalysisPromptBuilder.outputMarker)/tmp/foo",
            "Normal title"
        ]
        let extra = "Focus on \(AnalysisPromptBuilder.outputMarker)and the IPC layer"
        let prompt = build(titles: titles, extra: extra)

        // The marker should still appear exactly once, at the artifact path announcement.
        let occurrences = prompt.components(separatedBy: AnalysisPromptBuilder.outputMarker).count - 1
        #expect(occurrences == 1)

        // The path extraction should still work.
        let path = AnalysisPromptBuilder.outputPath(in: prompt)
        #expect(path == "/tmp/elliot/analyses/A/B/stories.json")

        // The sanitized content (without the marker) should still be in the prompt.
        #expect(prompt.contains("Crash when /tmp/foo"))
        #expect(prompt.contains("Focus on and the IPC layer"))
    }

    @Test("Paths with spaces (like the real default) are parsed whole")
    func pathsWithSpacesAreParsedWhole() {
        // The real default outputPath is ~/Library/Application Support/Elliot/analyses/A/B/stories.json
        // which contains two spaces. The parser must recover the entire path, not stop at the first space.
        let pathWithSpaces = "/Users/philippe/Library/Application Support/Elliot/analyses/A/B/stories.json"
        let prompt = AnalysisPromptBuilder.prompt(
            angle: .bugs,
            repoNameWithOwner: "phmatray/Elliot",
            outputPath: pathWithSpaces,
            existingTitles: [],
            maxStories: 8
        )

        // The path should be extracted whole, including all spaces.
        let extracted = AnalysisPromptBuilder.outputPath(in: prompt)
        #expect(extracted == pathWithSpaces)

        // The marker should still appear exactly once.
        let occurrences = prompt.components(separatedBy: AnalysisPromptBuilder.outputMarker).count - 1
        #expect(occurrences == 1)
    }
}
