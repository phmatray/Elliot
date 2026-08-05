import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine

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
        // `AnalysisService.start` computes its artifact path — and creates
        // the directory for it — through `StoreLocation`, even here where the
        // store is in-memory and nothing is actually spawned. `TestHome` is
        // the one place in this target permitted to point `ELLIOT_HOME`
        // somewhere other than the real `~/Library/Application Support/Elliot`.
        _ = TestHome.root
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

    @Test("The prompt lists what is already on the board, newest first")
    func promptCarriesExistingTitles() async throws {
        let fixture = try await makeFixture()
        let now = Date()
        // Saved directly rather than through `board.createCard`, which always
        // stamps `Date()`: the sort under test needs two real, distinct dates,
        // not two calls close enough together to land in the same millisecond.
        try await fixture.store.saveCard(Card(
            repoID: fixture.repo.id, title: "Older: cache the login shell environment",
            columnEnteredAt: now.addingTimeInterval(-3600),
            createdAt: now.addingTimeInterval(-3600), updatedAt: now.addingTimeInterval(-3600)
        ))
        try await fixture.store.saveCard(Card(
            repoID: fixture.repo.id, title: "Newer: retry the flaky verifier",
            columnEnteredAt: now, createdAt: now, updatedAt: now
        ))

        let started = try await fixture.service.start(
            repoID: fixture.repo.id, angles: [.bugs], origin: .manual
        )
        let prompt = started.runs[0].prompt
        #expect(prompt.contains("Older: cache the login shell environment"))
        #expect(prompt.contains("Newer: retry the flaky verifier"))
        let newer = try #require(prompt.range(of: "Newer: retry the flaky verifier"))
        let older = try #require(prompt.range(of: "Older: cache the login shell environment"))
        #expect(newer.lowerBound < older.lowerBound)
        // gh is unreachable here, so the prompt admits the check was partial.
        #expect(prompt.contains("could not be reached"))
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
        // Refused wholesale, by construction: `.tests` did not clash, but the
        // second call never queued anything at all, itself included.
        let runs = try await fixture.store.runs(repoID: fixture.repo.id)
        #expect(runs.count == 1)
        #expect(runs[0].analysisAngle == .bugs)
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

    private enum DecisionOutcome: Sendable {
        case accepted([Card])
        case rejected
    }

    @Test("Concurrent decisions on the same proposal are always coherent")
    func acceptRacesToOneCard() async throws {
        let fixture = try await makeFixture()
        let started = try await fixture.service.start(
            repoID: fixture.repo.id, angles: [.bugs], origin: .manual
        )
        let service = fixture.service
        let store = fixture.store

        // Part 1: accept vs. accept. `AnalysisService` is a reentrant actor:
        // `accept` awaits the store and the board more than once, so many
        // concurrent callers for the same id — a double-tap, a retried MCP
        // call — can each be scheduled between those suspension points. A
        // `TaskGroup` of several attempts gives the scheduler real
        // opportunities to interleave them, rather than hoping two `async
        // let`s happen to overlap.
        let proposal = StoryProposal(
            analysisID: started.analysis.id, runID: started.runs[0].id, repoID: fixture.repo.id,
            angle: .bugs, title: "Race me",
            story: UserStory(role: "dev", want: "w", benefit: "b"), createdAt: Date()
        )
        try await fixture.store.saveProposals([proposal])
        let proposalID = proposal.id
        let results = try await withThrowingTaskGroup(of: [Card].self) { group in
            for _ in 0..<8 {
                group.addTask { try await service.accept(proposalIDs: [proposalID]) }
            }
            var batches: [[Card]] = []
            for try await batch in group { batches.append(batch) }
            return batches
        }

        #expect(results.reduce(0) { $0 + $1.count } == 1)
        #expect(try await store.cards(repoID: fixture.repo.id).count == 1)

        // Part 2: accept vs. reject, on the same id. This is precisely the
        // interleaving Task 13's Analysis window makes reachable by an
        // ordinary double-click — Reject and → Backlog side by side, acting
        // on one multi-selection — not only by a contrived MCP retry.
        // Whichever wins, the result must be coherent: never a card on the
        // board whose source proposal reads `.rejected`, and never a
        // `.rejected` proposal that also grew a card.
        let second = StoryProposal(
            analysisID: started.analysis.id, runID: started.runs[0].id, repoID: fixture.repo.id,
            angle: .bugs, title: "Accept or reject me, never both",
            story: UserStory(role: "dev", want: "w", benefit: "b"), createdAt: Date()
        )
        try await store.saveProposals([second])
        let secondID = second.id
        let baselineCards = try await store.cards(repoID: fixture.repo.id).count

        // Two `reject`s bracketing one `accept`, `reject` first: `reject`'s
        // only awaited step between its read and its write is the write
        // itself, so a `reject` added first tends to win the read race
        // against `accept`'s claim, then land its unconditional write only
        // after `accept`'s longer claim-then-createCard-then-save chain has
        // already committed `.accepted` underneath it. Confirmed empirically
        // against the unfixed code below (see fix-round-2 report): this exact
        // shape reproduced the stomp in the high-90s percent of trials, where
        // a bare 1-vs-1 `async let` essentially never did.
        let outcomes = try await withThrowingTaskGroup(of: DecisionOutcome.self) { group in
            group.addTask {
                try await service.reject(proposalIDs: [secondID])
                return .rejected
            }
            group.addTask { .accepted(try await service.accept(proposalIDs: [secondID])) }
            group.addTask {
                try await service.reject(proposalIDs: [secondID])
                return .rejected
            }
            var all: [DecisionOutcome] = []
            for try await outcome in group { all.append(outcome) }
            return all
        }

        let cardsCreated = outcomes.flatMap { outcome -> [Card] in
            if case .accepted(let cards) = outcome { return cards }
            return []
        }
        let final = try #require(try await store.proposal(id: secondID))
        let cardsAfter = try await store.cards(repoID: fixture.repo.id).count

        switch final.status {
        case .accepted:
            #expect(cardsCreated.count == 1)
            #expect(final.acceptedCardID == cardsCreated.first?.id)
            #expect(cardsAfter == baselineCards + 1)
        case .rejected:
            #expect(cardsCreated.isEmpty)
            #expect(final.acceptedCardID == nil)
            #expect(cardsAfter == baselineCards)
        case .proposed:
            Issue.record("a decisive race left the proposal in .proposed")
        }
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
