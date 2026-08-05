import Testing

@testable import ElliotModel

@Suite("Text similarity")
struct TextSimilarityTests {

    @Test("Short words are noise and are dropped")
    func shortWordsAreDropped() {
        #expect(TextSimilarity.tokens("a to be or not to be") == ["not"])
    }

    @Test("Tokens ignore case and punctuation")
    func tokensNormalise() {
        #expect(TextSimilarity.tokens("Dark-Mode toggle!") == ["dark", "mode", "toggle"])
    }

    @Test("Overlap measures how much of the wanted vocabulary is covered")
    func overlapIsAsymmetric() {
        let wanted = TextSimilarity.tokens("dark mode toggle")
        #expect(TextSimilarity.overlap(wanted, TextSimilarity.tokens("Add a dark mode toggle")) == 1.0)
        #expect(TextSimilarity.overlap(wanted, TextSimilarity.tokens("dark mode")) > 0.6)
        #expect(TextSimilarity.overlap(wanted, TextSimilarity.tokens("rename the runner")) == 0.0)
        #expect(TextSimilarity.overlap([], TextSimilarity.tokens("anything")) == 0.0)
    }

    @Test("The best match is the highest scorer above the threshold")
    func bestMatchPicksTheHighest() throws {
        let candidates = ["Rename the runner", "Add a dark mode toggle", "Dark mode"]
        let match = try #require(TextSimilarity.bestMatch(for: "dark mode toggle", among: candidates))
        #expect(match.index == 1)
        #expect(match.score == 1.0)
    }

    @Test("Nothing above the threshold is no match, not a weak one")
    func belowThresholdIsNil() {
        #expect(TextSimilarity.bestMatch(for: "dark mode toggle", among: ["rename the runner"]) == nil)
    }
}
