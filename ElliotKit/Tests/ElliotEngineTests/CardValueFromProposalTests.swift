import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine

/// Records what would have been launched, without spawning anything.
private actor LaunchSpy: RunLaunching {
    func launch(runID: UUID) async {}
    func cancel(runID: UUID) async {}
}

/// The counterexample the design measures, driven end to end.
///
/// `ProposedStory.isUsable` only checks that the citation array is non-empty, so
/// a story citing `"   "` survives the decoder. `Evidence.parse` then returns
/// `nil` for a blank string and `ProposalHarvester.resolve` `compactMap`s it
/// away — so the proposal reaches the board with `evidence == []` while every
/// other field looks complete.
///
/// That card must fall to `.ungradeable`, not to a low score. Ranking it low
/// would put a card nothing could check *above* the cards nothing has read yet,
/// which is precisely the ordering `CardValue` refuses to invent.
@Suite("Card value from a real proposal")
struct CardValueFromProposalTests {

    private struct Fixture {
        var store: BoardStore
        var service: AnalysisService
        var harvester: ProposalHarvester
        var repo: Repo
        var analysis: Analysis
        var run: SkillRun
        var artifactURL: URL
        var root: URL

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    /// A throwaway repository with one real file, so a citation that *should*
    /// resolve has something true to resolve against.
    private func makeFixture() async throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elliot-value-\(UUID().uuidString)", isDirectory: true)
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "// real".write(
            to: sources.appendingPathComponent("Real.swift"), atomically: true, encoding: .utf8
        )

        let store = try BoardStore.inMemory()
        let repo = Repo(path: root.path, nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        try await store.saveRepo(repo)

        let analysis = Analysis(
            repoID: repo.id, angles: [.bugs], maxStoriesPerAngle: 8, createdAt: Date()
        )
        try await store.saveAnalysis(analysis)

        let run = SkillRun(
            cardID: nil, repoID: repo.id, analysisID: analysis.id, analysisAngle: .bugs,
            kind: .analyzeRepo, prompt: "…", cwd: repo.path,
            logPath: root.appendingPathComponent("run.ndjson").path,
            stderrPath: root.appendingPathComponent("run.log").path,
            createdAt: Date()
        )
        try await store.saveRun(run)

        // `gh` unreachable, so duplicate hints come from the board alone — which
        // is also the honest default here.
        let config = ToolConfig(
            claudePath: "/usr/bin/false", ghPath: "/usr/bin/false",
            gitPath: "/usr/bin/false", environment: [:]
        )
        let gh = GHClient(config: config)
        let spy = LaunchSpy()
        let board = BoardService(store: store, launcher: spy)

        return Fixture(
            store: store,
            service: AnalysisService(
                store: store, launcher: spy, board: board, gh: gh, gate: OpenGate()),
            harvester: ProposalHarvester(store: store, gh: gh),
            repo: repo, analysis: analysis, run: run,
            artifactURL: root.appendingPathComponent("stories.json"),
            root: root
        )
    }

    @Test("A story citing only whitespace becomes a card that cannot be ranked")
    func blankCitationEndsUpUngradeable() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        try """
        [
          {"title":"Cited only whitespace","role":"dev","want":"w","benefit":"b",
           "evidence":["   "],"effort":"small"},
          {"title":"Cited a real file","role":"dev","want":"w","benefit":"b",
           "evidence":["Sources/Real.swift:3"],"effort":"small"}
        ]
        """.write(to: fixture.artifactURL, atomically: true, encoding: .utf8)

        let report = await fixture.harvester.harvest(
            run: fixture.run, analysis: fixture.analysis,
            repo: fixture.repo, artifactURL: fixture.artifactURL
        )
        // Both were kept: `isUsable` looks at the array, not at what is in it.
        #expect(report.kept == 2)

        let proposals = try await fixture.store.proposals(analysisID: fixture.analysis.id)
        let blank = try #require(proposals.first { $0.title == "Cited only whitespace" })
        let real = try #require(proposals.first { $0.title == "Cited a real file" })
        // The measured step: the citation survived the decoder and was emptied
        // by the harvester.
        #expect(blank.evidence.isEmpty)
        #expect(blank.grounding == .notCited)
        #expect(real.grounding == .grounded)

        let cards = try await fixture.service.accept(proposalIDs: [blank.id, real.id])
        #expect(cards.count == 2)

        let blankCard = try #require(cards.first { $0.title == "Cited only whitespace" })
        let realCard = try #require(cards.first { $0.title == "Cited a real file" })

        // Refused, and refused for the reason it actually has — not ranked low.
        #expect(CardValue.of(blankCard) == .ungradeable(grounding: .notCited))
        #expect(CardValue.of(blankCard).rankable == nil)
        #expect(CardValue.of(realCard).rankable != nil)

        // And a ranking keeps it out of the order entirely rather than putting
        // it last, which is the whole claim.
        let ranking = CardRanking.rank([blankCard, realCard])
        #expect(ranking.ranked.map(\.card.title) == ["Cited a real file"])
        #expect(ranking.refused.map(\.card.title) == ["Cited only whitespace"])
    }
}
