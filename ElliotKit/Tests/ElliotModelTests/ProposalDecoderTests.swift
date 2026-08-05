import Foundation
import Testing

@testable import ElliotModel

/// Fixtures live at the repository root, not in a resource bundle: the same
/// files are opened by hand when reproducing a harvest.
private enum FixturePaths {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ElliotModelTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // ElliotKit
        .deletingLastPathComponent()   // repo root

    static func analysis(_ name: String) -> Data {
        (try? Data(contentsOf: root.appendingPathComponent("Fixtures/analysis/\(name)")))
            ?? Data()
    }
}

@Suite("Proposal decoder")
struct ProposalDecoderTests {

    @Test("A well-formed artifact decodes whole")
    func validArtifact() {
        let harvest = ProposalDecoder.decode(artifact: FixturePaths.analysis("valid.json"), maxStories: 8)
        #expect(harvest.stories.count == 2)
        #expect(harvest.dropped.isEmpty)
        #expect(harvest.stories[0].title == "Add --json to the preflight CLI")
        // Either spelling of the criteria key is accepted.
        #expect(harvest.stories[0].acceptanceCriteria.count == 2)
        #expect(harvest.stories[1].acceptanceCriteria == ["the capture is reused until ~/.zshrc changes"])
    }

    @Test("A wrapped array, unknown fields and unusable stories are all survivable")
    func messyArtifact() {
        let harvest = ProposalDecoder.decode(artifact: FixturePaths.analysis("messy.json"), maxStories: 8)
        #expect(harvest.stories.count == 1)
        #expect(harvest.stories[0].title == "Keep this one")
        #expect(Effort.parse(harvest.stories[0].effort) == .medium)
        #expect(harvest.dropped.count == 2)
        #expect(harvest.dropped.contains { $0.contains("No benefit") })
        #expect(harvest.dropped.contains { $0.contains("No evidence") })
    }

    @Test("Garbage is reported, not thrown", arguments: [
        "", "   ", "not json at all", "{}", "[1, 2, 3]", "{\"stories\": \"nope\"}",
    ])
    func garbageIsReported(raw: String) {
        let harvest = ProposalDecoder.decode(artifact: Data(raw.utf8), maxStories: 8)
        #expect(harvest.stories.isEmpty)
        #expect(!harvest.dropped.isEmpty)
    }

    @Test("Over the cap is trimmed, and the trim is announced")
    func capIsAnnounced() {
        let many = (1...30).map {
            """
            {"title":"S\($0)","role":"dev","want":"w","benefit":"b","evidence":["A.swift:1"]}
            """
        }.joined(separator: ",")
        let harvest = ProposalDecoder.decode(artifact: Data("[\(many)]".utf8), maxStories: 8)
        #expect(harvest.stories.count == 8)
        #expect(harvest.dropped.contains { $0.contains("22") })
    }

    @Test("The fenced-block fallback recovers an array from prose")
    func fencedFallback() {
        let text = """
            I looked at the runner and found two things worth filing.

            ```json
            [{"title":"T","role":"dev","want":"w","benefit":"b","evidence":["A.swift:1"]}]
            ```

            Let me know if you want more detail.
            """
        let harvest = ProposalDecoder.decode(resultText: text, maxStories: 8)
        #expect(harvest.stories.count == 1)
        #expect(harvest.stories[0].title == "T")
    }

    @Test("The last fenced block wins, so a schema echoed earlier does not")
    func lastFenceWins() {
        let text = """
            Here is the shape I will use:

            ```json
            [{"title":"EXAMPLE","role":"","want":"","benefit":"","evidence":[]}]
            ```

            And here is the result:

            ```json
            [{"title":"REAL","role":"dev","want":"w","benefit":"b","evidence":["A.swift:1"]}]
            ```
            """
        let harvest = ProposalDecoder.decode(resultText: text, maxStories: 8)
        #expect(harvest.stories.map(\.title) == ["REAL"])
    }

    @Test("Prose with no fenced block yields nothing and says so")
    func noFenceNoStories() {
        let harvest = ProposalDecoder.decode(resultText: "I could not find anything.", maxStories: 8)
        #expect(harvest.stories.isEmpty)
        #expect(harvest.dropped.contains { $0.lowercased().contains("no json") })
    }
}
