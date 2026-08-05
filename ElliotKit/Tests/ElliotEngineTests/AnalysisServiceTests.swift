import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine

/// `ELLIOT_HOME` is unset by default, which points `StoreLocation` at the real
/// `~/Library/Application Support/Elliot` — a directory these tests have no
/// business writing into, and whose path contains a space that breaks
/// `AnalysisPromptBuilder.outputPath(in:)`'s whitespace-delimited parsing (it
/// stops at "Application", before "Support"). Set once per process to a
/// scratch directory that has neither problem. Only if unset, so a shared
/// process-wide home set by another suite is left alone.
private let elliotHomeConfiguredForTests: Void = {
    guard ProcessInfo.processInfo.environment["ELLIOT_HOME"] == nil else { return }
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("elliot-analysis-service-tests-\(ProcessInfo.processInfo.processIdentifier)")
    setenv("ELLIOT_HOME", url.path, 1)
}()

/// Records what would have been launched, without spawning anything.
private actor LaunchSpy: RunLaunching {
    private(set) var launched: [UUID] = []
    func launch(runID: UUID) async { launched.append(runID) }
    func cancel(runID: UUID) async {}
    func ids() -> [UUID] { launched }
}

@Suite("Analysis service")
struct AnalysisServiceTests {

    private struct Fixture {
        var store: BoardStore
        var service: AnalysisService
        var board: BoardService
        var spy: LaunchSpy
        var repo: Repo
    }

    private func makeFixture(enabled: Bool = true) async throws -> Fixture {
        _ = elliotHomeConfiguredForTests
        let store = try BoardStore.inMemory()
        let config = ToolConfig(
            claudePath: "/usr/bin/false", ghPath: "/usr/bin/false",
            gitPath: "/usr/bin/false", environment: [:]
        )
        let spy = LaunchSpy()
        let board = BoardService(store: store, launcher: spy)
        let service = AnalysisService(
            store: store, launcher: spy, board: board, gh: GHClient(config: config)
        )
        var repo = Repo(path: "/tmp/r", nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        repo.isEnabled = enabled
        try await store.saveRepo(repo)
        return Fixture(store: store, service: service, board: board, spy: spy, repo: repo)
    }

    @Test("Starting an analysis queues one run per angle, each with its own prompt")
    func oneRunPerAngle() async throws {
        let fixture = try await makeFixture()
        let started = try await fixture.service.start(
            repoID: fixture.repo.id, angles: [.bugs, .quickWins, .tests],
            extraInstructions: "focus on ElliotProcess", maxStoriesPerAngle: 5, origin: .manual
        )

        #expect(started.runs.count == 3)
        #expect(Set(started.runs.compactMap(\.analysisAngle)) == [.bugs, .quickWins, .tests])
        #expect(started.runs.allSatisfy { $0.kind == .analyzeRepo })
        #expect(started.runs.allSatisfy { $0.cardID == nil })
        #expect(started.runs.allSatisfy { $0.analysisID == started.analysis.id })
        #expect(started.runs.allSatisfy { $0.state == .queued })
        #expect(await fixture.spy.ids().count == 3)

        // Each prompt announces its own artifact, and only its own.
        for run in started.runs {
            let path = try #require(AnalysisPromptBuilder.outputPath(in: run.prompt))
            #expect(path.hasSuffix("/\(run.id.uuidString)/stories.json"))
            #expect(run.prompt.contains("focus on ElliotProcess"))
            #expect(run.prompt.contains("phmatray/Elliot"))
        }
        // Three distinct artifacts, so two angles cannot overwrite each other.
        let paths = started.runs.compactMap { AnalysisPromptBuilder.outputPath(in: $0.prompt) }
        #expect(Set(paths).count == 3)
    }

    @Test("The prompt lists what is already on the board")
    func promptCarriesExistingTitles() async throws {
        let fixture = try await makeFixture()
        _ = try await fixture.board.createCard(
            repoID: fixture.repo.id, title: "Cache the login shell environment"
        )
        let started = try await fixture.service.start(
            repoID: fixture.repo.id, angles: [.bugs], origin: .manual
        )
        #expect(started.runs[0].prompt.contains("Cache the login shell environment"))
        // gh is unreachable here, so the prompt admits the check was partial.
        #expect(started.runs[0].prompt.contains("could not be reached"))
    }

    @Test("A second run of an angle already in flight is refused, not queued")
    func angleDedupe() async throws {
        let fixture = try await makeFixture()
        _ = try await fixture.service.start(
            repoID: fixture.repo.id, angles: [.bugs], origin: .manual
        )
        await #expect(throws: AnalysisError.self) {
            try await fixture.service.start(
                repoID: fixture.repo.id, angles: [.bugs, .tests], origin: .mcp(client: "x")
            )
        }
    }

    @Test("A disabled repository is refused, and no angles at all is refused")
    func refusals() async throws {
        let disabled = try await makeFixture(enabled: false)
        await #expect(throws: AnalysisError.self) {
            try await disabled.service.start(repoID: disabled.repo.id, angles: [.bugs], origin: .manual)
        }
        let fixture = try await makeFixture()
        await #expect(throws: AnalysisError.self) {
            try await fixture.service.start(repoID: fixture.repo.id, angles: [], origin: .manual)
        }
        await #expect(throws: AnalysisError.self) {
            try await fixture.service.start(repoID: UUID(), angles: [.bugs], origin: .manual)
        }
    }

    @Test("Accepting a proposal lands a Backlog card and runs nothing")
    func acceptCreatesCards() async throws {
        let fixture = try await makeFixture()
        let started = try await fixture.service.start(
            repoID: fixture.repo.id, angles: [.quickWins], origin: .manual
        )
        let proposal = StoryProposal(
            analysisID: started.analysis.id, runID: started.runs[0].id, repoID: fixture.repo.id,
            angle: .quickWins, title: "Add --json to preflight",
            story: UserStory(
                role: "developer", want: "preflight as JSON",
                benefit: "I can gate CI on it", acceptanceCriteria: ["one object per check"]
            ),
            createdAt: Date()
        )
        try await fixture.store.saveProposals([proposal])

        let launchedBefore = await fixture.spy.ids().count
        let cards = try await fixture.service.accept(proposalIDs: [proposal.id])

        #expect(cards.count == 1)
        #expect(cards[0].column == .backlog)
        #expect(cards[0].title == "Add --json to preflight")
        #expect(cards[0].story?.isComplete == true)
        // A card in Backlog fires nothing. Only backlog → todo does.
        #expect(await fixture.spy.ids().count == launchedBefore)

        let back = try #require(try await fixture.store.proposal(id: proposal.id))
        #expect(back.status == .accepted)
        #expect(back.acceptedCardID == cards[0].id)
    }

    @Test("Accepting the same proposal twice creates one card")
    func acceptIsIdempotent() async throws {
        let fixture = try await makeFixture()
        let started = try await fixture.service.start(
            repoID: fixture.repo.id, angles: [.bugs], origin: .manual
        )
        let proposal = StoryProposal(
            analysisID: started.analysis.id, runID: started.runs[0].id, repoID: fixture.repo.id,
            angle: .bugs, title: "Once",
            story: UserStory(role: "dev", want: "w", benefit: "b"), createdAt: Date()
        )
        try await fixture.store.saveProposals([proposal])

        _ = try await fixture.service.accept(proposalIDs: [proposal.id])
        let second = try await fixture.service.accept(proposalIDs: [proposal.id])
        #expect(second.isEmpty)
        #expect(try await fixture.store.cards(repoID: fixture.repo.id).count == 1)
    }

    @Test("Rejecting marks without deleting, so the analysis stays readable")
    func rejectMarks() async throws {
        let fixture = try await makeFixture()
        let started = try await fixture.service.start(
            repoID: fixture.repo.id, angles: [.bugs], origin: .manual
        )
        let proposal = StoryProposal(
            analysisID: started.analysis.id, runID: started.runs[0].id, repoID: fixture.repo.id,
            angle: .bugs, title: "No thanks",
            story: UserStory(role: "dev", want: "w", benefit: "b"), createdAt: Date()
        )
        try await fixture.store.saveProposals([proposal])

        try await fixture.service.reject(proposalIDs: [proposal.id])
        #expect(try await fixture.store.proposal(id: proposal.id)?.status == .rejected)
        #expect(try await fixture.store.proposals(analysisID: started.analysis.id).count == 1)
    }

    @Test("An edited proposal is what becomes the card")
    func editsWinOverTheModel() async throws {
        let fixture = try await makeFixture()
        let started = try await fixture.service.start(
            repoID: fixture.repo.id, angles: [.bugs], origin: .manual
        )
        var proposal = StoryProposal(
            analysisID: started.analysis.id, runID: started.runs[0].id, repoID: fixture.repo.id,
            angle: .bugs, title: "Model's title",
            story: UserStory(role: "dev", want: "vague", benefit: "b"), createdAt: Date()
        )
        try await fixture.store.saveProposals([proposal])

        proposal.title = "My title"
        proposal.story.want = "something precise"
        try await fixture.service.updateProposal(proposal)

        let cards = try await fixture.service.accept(proposalIDs: [proposal.id])
        #expect(cards[0].title == "My title")
        #expect(cards[0].story?.want == "something precise")
    }
}
