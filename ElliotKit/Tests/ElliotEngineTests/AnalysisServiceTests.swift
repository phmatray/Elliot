import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import TestSupport
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

    /// A gate that states a verdict instead of running six subprocesses and a
    /// networked `gh label list` for one.
    ///
    /// The whole reason `RepoGating` is a protocol rather than a
    /// `PreflightService` parameter: the service's own refusal is what these
    /// tests are about, and a real sweep would make them measure Preflight.
    private struct StubGate: RepoGating {
        let state: PreflightState
        func verdict(for repo: Repo) async -> PreflightState { state }
    }

    private func makeFixture(
        enabled: Bool = true, gate: any RepoGating = OpenGate()
    ) async throws -> Fixture {
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
            store: store, launcher: spy, board: board, gh: GHClient(config: config), gate: gate
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

    /// ⚠️ **The disabled-repository clause moved out of here**, to
    /// ``disabledIsRefusedByTheRule``, which names the case rather than
    /// accepting any `AnalysisError`. Two tests over one guard is not belt and
    /// braces when the weaker one would go green on the wrong refusal — and this
    /// one would, now that a second guard throws the same error type.
    ///
    /// What is left is genuinely uncovered elsewhere: an empty angle set, and a
    /// repository id that names nothing.
    @Test("No angles at all is refused, and so is an unknown repository")
    func refusals() async throws {
        let fixture = try await makeFixture()
        await #expect(throws: AnalysisError.self) {
            try await fixture.service.start(repoID: fixture.repo.id, angles: [], origin: .manual)
        }
        await #expect(throws: AnalysisError.self) {
            try await fixture.service.start(repoID: UUID(), angles: [.bugs], origin: .manual)
        }
    }

    // MARK: - The one rule, asked by its second caller

    /// ⛔ **The guarantee this suite did not hold until the gate existed.**
    ///
    /// `start` checked `isEnabled` and the in-flight dedupe and nothing else, so
    /// up to eight unattended `claude -p` runs could begin at
    /// `bypassPermissions` inside a checkout Preflight had already diagnosed as
    /// broken. The only gate on this path was a computed property on a SwiftUI
    /// model, which #151 nearly deleted — and which no service can reach anyway.
    @Test("An analysis is refused for a repository Preflight is failing")
    func analysisIsGatedOnPreflight() async throws {
        let fixture = try await makeFixture(gate: StubGate(state: .failing))

        await #expect(throws: AnalysisError.repoRefused(.preflightBlocked)) {
            try await fixture.service.start(
                repoID: fixture.repo.id, angles: [.bugs], origin: .manual)
        }
        // Refused on the act, not on the reply: nothing was queued and nothing
        // was handed to the launcher.
        #expect(try await fixture.store.runs(repoID: fixture.repo.id).isEmpty)
        #expect(await fixture.spy.ids().isEmpty)
    }

    /// The same refusal for the other guard, through the same rule and the same
    /// error case — so the sentence the reader sees is the rule's, once.
    @Test("A disabled repository is refused by the same rule, and says which")
    func disabledIsRefusedByTheRule() async throws {
        let fixture = try await makeFixture(enabled: false)

        await #expect(throws: AnalysisError.repoRefused(.repoDisabled)) {
            try await fixture.service.start(
                repoID: fixture.repo.id, angles: [.bugs], origin: .manual)
        }
        #expect(try await fixture.store.runs(repoID: fixture.repo.id).isEmpty)
    }

    /// ⛔ **The order is the rule's, and this caller does not get to re-derive
    /// it.**
    ///
    /// A repository can be both switched off and failing a check. Naming the
    /// diagnosis first sends someone hunting a finding when the answer is a
    /// toggle they threw themselves, which is why `evaluateMove` asks
    /// `repoIsEnabled` before `repoPreflight` and why `refusal(repo:preflight:)`
    /// does too. Pinned here because a caller that short-circuited the gate to
    /// save a probe would have to know this order — and a second copy of an
    /// ordering is what the whole refactor removed.
    @Test("Switched off wins over failing, because the rule says so")
    func disabledWinsOverBlocked() async throws {
        let fixture = try await makeFixture(enabled: false, gate: StubGate(state: .failing))

        await #expect(throws: AnalysisError.repoRefused(.repoDisabled)) {
            try await fixture.service.start(
                repoID: fixture.repo.id, angles: [.bugs], origin: .manual)
        }
    }

    /// ⚠️ **`notChecked` permits, and this service is where that costs the
    /// most.**
    ///
    /// It is the board's answer too — blocking would freeze every repository for
    /// the first seconds of each launch, and permanently whenever a rate-limited
    /// `gh label list` stops a sweep finishing — but the board is a person
    /// dragging one card, and this is up to eight unattended agents. So the
    /// decision is asserted at this caller rather than inherited silently: an
    /// analysis in a repository nobody has swept **starts**.
    @Test("A repository nobody has swept still starts, deliberately")
    func nobodySweptStillStarts() async throws {
        let fixture = try await makeFixture(gate: StubGate(state: .notChecked))

        let started = try await fixture.service.start(
            repoID: fixture.repo.id, angles: [.bugs], origin: .manual)

        #expect(started.runs.count == 1)
        #expect(await fixture.spy.ids().count == 1)
    }

    /// The positive witness for all four above: a swept, clear repository starts.
    ///
    /// Without it the suite could be satisfied by a `start` that refuses
    /// everything, which is the failure direction a gate makes easy.
    @Test("A repository swept clear starts")
    func sweptClearStarts() async throws {
        let fixture = try await makeFixture(gate: StubGate(state: .passing))

        let started = try await fixture.service.start(
            repoID: fixture.repo.id, angles: [.bugs], origin: .manual)

        #expect(started.runs.count == 1)
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

    /// The point of the whole change: the lens chosen before the run is still
    /// attached to the work after it. Two proposals from different lenses, so a
    /// hardcoded angle would not pass.
    @Test("Accepting a proposal puts its lens on the card")
    func acceptCarriesTheAngle() async throws {
        let fixture = try await makeFixture()
        let started = try await fixture.service.start(
            repoID: fixture.repo.id, angles: [.bugs, .techDebt], origin: .manual
        )

        func proposal(_ angle: AnalysisAngle, _ title: String) -> StoryProposal {
            StoryProposal(
                analysisID: started.analysis.id, runID: started.runs[0].id,
                repoID: fixture.repo.id, angle: angle, title: title,
                story: UserStory(role: "maintainer", want: title, benefit: "it is better"),
                createdAt: Date()
            )
        }
        let bug = proposal(.bugs, "Bound the await")
        let debt = proposal(.techDebt, "Split the file")
        try await fixture.store.saveProposals([bug, debt])

        let cards = try await fixture.service.accept(proposalIDs: [bug.id, debt.id])

        #expect(cards.count == 2)
        #expect(cards.first { $0.title == "Bound the await" }?.angle == .bugs)
        #expect(cards.first { $0.title == "Split the file" }?.angle == .techDebt)

        // And it is on the row, not only on the value that was handed back —
        // the card is read from the store on every launch, and an angle that
        // never reached SQLite would vanish at the next one.
        let stored = try await fixture.store.cards(repoID: fixture.repo.id)
        #expect(stored.first { $0.title == "Bound the await" }?.angle == .bugs)
        #expect(stored.first { $0.title == "Split the file" }?.angle == .techDebt)
    }

    /// The other half of the same loss. The analysis established an effort and
    /// resolved every citation against the repository root, and both died at
    /// `accept` — so the Backlog carried almost nothing to rank by.
    ///
    /// `appraisedAt` is the proposal's own moment, not `now`: that is when the
    /// harvest resolved the citations, and dating the reading to whenever
    /// somebody clicked Accept would make an old proposal look freshly measured.
    @Test("Accepting a proposal puts its effort, evidence and reading time on the card")
    func acceptCarriesTheAppraisal() async throws {
        let fixture = try await makeFixture()
        let started = try await fixture.service.start(
            repoID: fixture.repo.id, angles: [.bugs], origin: .manual
        )
        let read = Date(timeIntervalSince1970: 1_700_000_000)

        let proposal = StoryProposal(
            analysisID: started.analysis.id, runID: started.runs[0].id,
            repoID: fixture.repo.id, angle: .bugs, title: "Bound the await",
            story: UserStory(role: "maintainer", want: "a bounded wait", benefit: "no hangs"),
            evidence: [
                Evidence(path: "Sources/ElliotProcess/ChildProcess.swift", line: 142, exists: true),
                Evidence(path: "Sources/Nowhere.swift", line: 9, exists: false),
            ],
            effort: .large,
            createdAt: read
        )
        try await fixture.store.saveProposals([proposal])

        let cards = try await fixture.service.accept(proposalIDs: [proposal.id])

        #expect(cards.count == 1)
        #expect(cards[0].effort == .large)
        #expect(cards[0].evidence?.count == 2)
        #expect(cards[0].appraisedAt == read)

        // And it is on the row, not only on the value handed back — the card is
        // read from the store on every launch, and an appraisal that never
        // reached SQLite would vanish at the next one.
        let stored = try #require(try await fixture.store.card(id: cards[0].id))
        #expect(stored.effort == .large)
        #expect(stored.evidence?.first?.path == "Sources/ElliotProcess/ChildProcess.swift")
        #expect(stored.evidence?.first?.line == 142)
        #expect(stored.evidence?.first?.exists == true)
        // The resolution survives the round trip, which is the only reason
        // `Grounding` can be computed from the card at all.
        #expect(stored.evidence?.last?.exists == false)
        #expect(stored.appraisedAt == read)
        #expect(CardValue.of(stored) == .ranked(
            score: AnalysisAngle.bugs.valueWeight
                + Effort.large.valueWeight
                + Grounding.missing(count: 1).valueWeight,
            because: [
                Signal(name: "bugs", weight: AnalysisAngle.bugs.valueWeight),
                Signal(name: "large", weight: Effort.large.valueWeight),
                Signal(name: "files_missing", weight: Grounding.missing(count: 1).valueWeight),
            ]
        ))
    }

    /// A card the board makes for itself still carries no appraisal, because
    /// nothing read it. `nil` here is the third state, not a zero.
    @Test("A card created directly has never been appraised")
    func directCreateHasNoAppraisal() async throws {
        let fixture = try await makeFixture()
        let created = try await fixture.board.createCard(
            repoID: fixture.repo.id, title: "Written by hand"
        )
        #expect(created.card.effort == nil)
        #expect(created.card.evidence == nil)
        #expect(created.card.appraisedAt == nil)
        #expect(CardValue.of(created.card) == .neverAppraised)
    }

    /// The other half of the claim: a card the board makes for itself still has
    /// no lens, because it was not found through one.
    @Test("A card created directly has no lens")
    func directCreateHasNoAngle() async throws {
        let fixture = try await makeFixture()
        let created = try await fixture.board.createCard(
            repoID: fixture.repo.id, title: "Written by hand"
        )
        #expect(created.card.angle == nil)
        #expect(created.card.labels == [], "and no label it did not ask for")
    }

    /// A **visible pre-fill**, which is the whole distinction this issue turns
    /// on: the label arrives as ordinary card data, in the editor, where a
    /// human can see it and take it off — not as a rule applied on the way past.
    ///
    /// Three lenses, deliberately: one that means a label, one that means a
    /// different label, and one that honestly means none. A single case would
    /// pass against a hardcoded `"bug"`, and the `nil` case is the half that
    /// matters most — five of the eight lenses take it, and a map that answered
    /// "enhancement" for all of them would put a chosen-looking label on cards
    /// nobody chose.
    @Test("An accepted proposal arrives carrying its lens's label, and only an honest one")
    func acceptSeedsTheLensLabel() async throws {
        let fixture = try await makeFixture()
        let started = try await fixture.service.start(
            repoID: fixture.repo.id, angles: [.bugs, .docsAndDX, .techDebt], origin: .manual
        )

        func proposal(_ angle: AnalysisAngle, _ title: String) -> StoryProposal {
            StoryProposal(
                analysisID: started.analysis.id, runID: started.runs[0].id,
                repoID: fixture.repo.id, angle: angle, title: title,
                story: UserStory(role: "maintainer", want: title, benefit: "it is better"),
                createdAt: Date()
            )
        }
        let bug = proposal(.bugs, "Bound the await")
        let docs = proposal(.docsAndDX, "Write the runbook")
        let debt = proposal(.techDebt, "Split the file")
        try await fixture.store.saveProposals([bug, docs, debt])

        _ = try await fixture.service.accept(proposalIDs: [bug.id, docs.id, debt.id])

        // Read from the store, not from the returned values: the card is loaded
        // fresh on every launch, and a label that never reached SQLite would be
        // gone by the next one.
        let stored = try await fixture.store.cards(repoID: fixture.repo.id)
        #expect(stored.first { $0.title == "Bound the await" }?.labels == ["bug"])
        #expect(stored.first { $0.title == "Write the runbook" }?.labels == ["documentation"])
        #expect(
            stored.first { $0.title == "Split the file" }?.labels == [],
            "tech debt is a claim about where the work is, not about what kind of issue it is"
        )
    }

    /// The seeded label is a suggestion, not a fact about the card, so it obeys
    /// the ordinary edit rule: removable until the card is filed. A pre-fill
    /// that could not be taken off would be the invisible rule wearing a
    /// visible costume.
    @Test("A seeded label is ordinary card data a human can remove")
    func seededLabelIsRemovable() async throws {
        let fixture = try await makeFixture()
        let started = try await fixture.service.start(
            repoID: fixture.repo.id, angles: [.bugs], origin: .manual
        )
        let bug = StoryProposal(
            analysisID: started.analysis.id, runID: started.runs[0].id,
            repoID: fixture.repo.id, angle: .bugs, title: "Bound the await",
            story: UserStory(role: "maintainer", want: "a bound", benefit: "no hang"),
            createdAt: Date()
        )
        try await fixture.store.saveProposals([bug])

        let card = try await fixture.service.accept(proposalIDs: [bug.id])[0]
        #expect(card.labels == ["bug"])

        try await fixture.board.updateCard(
            id: card.id, title: card.title, body: card.body, story: card.story, labels: []
        )
        #expect(try await fixture.store.card(id: card.id)?.labels == [])
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

    // MARK: - Restoring

    /// The promise `reject`'s own comment makes — *"an analysis you have been
    /// through should still read as what it found, including what you turned
    /// down"* — was only half kept: the row survived and nothing could reach it
    /// (#292). Round-tripped through `accept` at the end, because a proposal put
    /// back that cannot then be accepted is a list entry, not an undo.
    @Test("A rejected proposal can be put back, and accepted afterwards")
    func restorePutsItBack() async throws {
        let fixture = try await makeFixture()
        let started = try await fixture.service.start(
            repoID: fixture.repo.id, angles: [.bugs], origin: .manual
        )
        let proposal = StoryProposal(
            analysisID: started.analysis.id, runID: started.runs[0].id, repoID: fixture.repo.id,
            angle: .bugs, title: "Rejected by mistake",
            story: UserStory(role: "dev", want: "w", benefit: "b"), createdAt: Date()
        )
        try await fixture.store.saveProposals([proposal])

        try await fixture.service.reject(proposalIDs: [proposal.id])
        #expect(try await fixture.store.proposal(id: proposal.id)?.status == .rejected)

        #expect(try await fixture.service.restore(proposalIDs: [proposal.id]) == 1)
        #expect(try await fixture.store.proposal(id: proposal.id)?.status == .proposed)

        // `#require`, not `cards[0]`: a broken round trip returns an empty
        // array, and subscripting it traps — which aborts the whole run with a
        // signal rather than failing this test, taking every result after it
        // with it. Found by break-testing this very guarantee.
        let cards = try await fixture.service.accept(proposalIDs: [proposal.id])
        #expect(cards.count == 1)
        #expect(try #require(cards.first).title == "Rejected by mistake")
    }

    /// The count is what the panel's sentence is built from, so it has to be
    /// what the store changed rather than what the caller asked for. Reporting
    /// `proposalIDs.count` here would announce "Restored 2" over a list where
    /// one row stayed exactly where it was.
    @Test("Restore counts what actually moved, never what was asked for")
    func restoreCountsTheClaimsItWon() async throws {
        let fixture = try await makeFixture()
        let started = try await fixture.service.start(
            repoID: fixture.repo.id, angles: [.bugs], origin: .manual
        )
        func proposal(_ title: String) -> StoryProposal {
            StoryProposal(
                analysisID: started.analysis.id, runID: started.runs[0].id,
                repoID: fixture.repo.id, angle: .bugs, title: title,
                story: UserStory(role: "dev", want: "w", benefit: "b"), createdAt: Date()
            )
        }
        let turnedDown = proposal("Turned down")
        let neverDecided = proposal("Never decided")
        try await fixture.store.saveProposals([turnedDown, neverDecided])
        try await fixture.service.reject(proposalIDs: [turnedDown.id])

        // One is restorable, one was never rejected — so one claim can win.
        let restored = try await fixture.service.restore(
            proposalIDs: [turnedDown.id, neverDecided.id]
        )
        #expect(restored == 1)
        // Restoring the same one twice wins nothing the second time: the row is
        // no longer `.rejected`, which is the compare-and-set doing its job.
        #expect(try await fixture.service.restore(proposalIDs: [turnedDown.id]) == 0)
    }

    /// The defect the issue names as the thing to watch. A proposal that has
    /// produced a card must not come back to the list, or accepting it again
    /// gives one story two Backlog cards — and the count must say it did not
    /// move, so the panel does not report a success the list contradicts.
    @Test("A rejected proposal carrying a card is refused, and no second card is made")
    func restoreRefusesOneThatAlreadyGrewACard() async throws {
        let fixture = try await makeFixture()
        let started = try await fixture.service.start(
            repoID: fixture.repo.id, angles: [.bugs], origin: .manual
        )
        let proposal = StoryProposal(
            analysisID: started.analysis.id, runID: started.runs[0].id, repoID: fixture.repo.id,
            angle: .bugs, title: "Accepted, then marked rejected",
            story: UserStory(role: "dev", want: "w", benefit: "b"), createdAt: Date()
        )
        try await fixture.store.saveProposals([proposal])

        // Accept it for real, so a card genuinely exists and the backlink is
        // the store's own, then force the row to `.rejected` behind the
        // service's back. That combination is not reachable through the claims
        // any more; it is what the reject race documented in `AnalysisService`
        // could leave behind before it was fixed, and those rows are in the
        // field.
        let cards = try await fixture.service.accept(proposalIDs: [proposal.id])
        let card = try #require(cards.first, "the set-up accept did not make a card")
        var stranded = try #require(try await fixture.store.proposal(id: proposal.id))
        #expect(stranded.acceptedCardID == card.id)
        stranded.status = .rejected
        try await fixture.store.saveProposal(stranded)

        #expect(try await fixture.service.restore(proposalIDs: [stranded.id]) == 0)
        #expect(try await fixture.store.proposal(id: stranded.id)?.status == .rejected)

        // The proof that matters is on the board, not on the row: a restore
        // that got through would be followed by an accept, and that is where
        // the second card would appear.
        _ = try await fixture.service.accept(proposalIDs: [stranded.id])
        #expect(try await fixture.store.cards(repoID: fixture.repo.id).count == 1)
    }

    /// Restore joins the same three-way race `accept` and `reject` already run:
    /// whichever the store serializes first is the only one that acts, and no
    /// interleaving may leave a card on the board twice.
    @Test("Restore racing an accept never yields two cards")
    func restoreRacesAcceptCoherently() async throws {
        let fixture = try await makeFixture()
        let started = try await fixture.service.start(
            repoID: fixture.repo.id, angles: [.bugs], origin: .manual
        )
        let service = fixture.service
        let store = fixture.store
        let proposal = StoryProposal(
            analysisID: started.analysis.id, runID: started.runs[0].id, repoID: fixture.repo.id,
            angle: .bugs, title: "Restore or accept me, never both twice",
            story: UserStory(role: "dev", want: "w", benefit: "b"), createdAt: Date()
        )
        try await store.saveProposals([proposal])
        let id = proposal.id
        try await service.reject(proposalIDs: [id])

        // Restores and accepts interleaved over one id. An accept can only win
        // after some restore has put the row back, so the outcome is either
        // "still rejected, no card" or "accepted, exactly one card" — never a
        // second one.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { _ = try? await service.restore(proposalIDs: [id]) }
                group.addTask { _ = try? await service.accept(proposalIDs: [id]) }
            }
        }

        let final = try #require(try await store.proposal(id: id))
        let cards = try await store.cards(repoID: fixture.repo.id)
        switch final.status {
        case .accepted:
            #expect(cards.count == 1)
            #expect(final.acceptedCardID == cards.first?.id)
        case .rejected, .proposed:
            #expect(cards.isEmpty)
            #expect(final.acceptedCardID == nil)
        }
    }

    // MARK: - Harvesting again, from the file already on disk (#330)

    /// The crash state, **seeded rather than simulated**: a terminal analysis
    /// run carrying the `kept: 0` report `Reconciler.sweep` writes, and a
    /// `stories.json` sitting at the path `StoreLocation` promises it is kept at.
    private struct Orphan {
        var analysis: Analysis
        var run: SkillRun
        var artifactURL: URL
    }

    private func seedOrphanedRun(
        _ fixture: Fixture,
        stories: String = """
            [
              {"title":"Bound the await","role":"dev","want":"a bound","benefit":"no hangs",
               "evidence":["Sources/Real.swift:3"],"effort":"small"},
              {"title":"Drain under the lock","role":"dev","want":"one drain","benefit":"no lost tails",
               "evidence":["Sources/Real.swift:9"],"effort":"medium"}
            ]
            """,
        report: AnalysisRunReport? = AnalysisRunReport(
            harvestSource: .none, dropped: ["Elliot stopped before this run was harvested."]
        ),
        state: RunState = .failed
    ) async throws -> Orphan {
        let started = try await fixture.service.start(
            repoID: fixture.repo.id, angles: [.bugs], origin: .manual
        )
        var run = started.runs[0]
        run.state = state
        run.analysisReport = report
        try await fixture.store.saveRun(run)

        let artifactURL = StoreLocation.analysisArtifactURL(
            analysisID: started.analysis.id, runID: run.id
        )
        try FileManager.default.createDirectory(
            at: artifactURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try stories.write(to: artifactURL, atomically: true, encoding: .utf8)

        return Orphan(analysis: started.analysis, run: run, artifactURL: artifactURL)
    }

    /// Criterion 2 and 3 together, and the whole point of the feature: the file
    /// the run was *told* to write is still the fact, an hour later.
    @Test("A finished lens can be harvested again from the artifact it already wrote")
    func reharvestReadsTheFile() async throws {
        let fixture = try await makeFixture()
        let orphan = try await seedOrphanedRun(fixture)
        defer { try? FileManager.default.removeItem(at: orphan.artifactURL) }

        let report = try await fixture.service.reharvest(runID: orphan.run.id)

        #expect(report.harvestSource == .artifact)
        #expect(report.kept == 2)

        let landed = try await fixture.store.proposals(runID: orphan.run.id)
        #expect(Set(landed.map(\.title)) == ["Bound the await", "Drain under the lock"])
        #expect(landed.allSatisfy { $0.analysisID == orphan.analysis.id })
        #expect(landed.allSatisfy { $0.angle == .bugs })

        // Criterion 3: the run's own row carries the new report, not only the
        // value handed back. A report that never reached SQLite would be gone
        // at the next launch, which is exactly the state this recovers from.
        let stored = try #require(try await fixture.store.run(id: orphan.run.id))
        #expect(stored.analysisReport?.harvestSource == .artifact)
        #expect(stored.analysisReport?.kept == 2)
        #expect(
            stored.analysisReport?.dropped.isEmpty == true,
            "the previous harvest's complaint about a file it never opened must not survive it")
    }

    /// Criterion 2 — *"spawns no process"* — turned into an assertion rather
    /// than a hope. `LaunchSpy` is the existing recorder; the run table is the
    /// second witness, because a launch that somehow got through would leave a
    /// row behind even if the spy were wired wrong.
    @Test("Harvesting again launches nothing and adds no run")
    func reharvestSpawnsNothing() async throws {
        let fixture = try await makeFixture()
        let orphan = try await seedOrphanedRun(fixture)
        defer { try? FileManager.default.removeItem(at: orphan.artifactURL) }

        // `start` launched exactly one run to set this up; nothing after it may.
        let launchedBefore = await fixture.spy.ids()
        #expect(launchedBefore == [orphan.run.id])

        _ = try await fixture.service.reharvest(runID: orphan.run.id)

        #expect(await fixture.spy.ids() == launchedBefore)
        let runs = try await fixture.store.runs(analysisID: orphan.analysis.id)
        #expect(runs.count == 1)
        #expect(runs[0].id == orphan.run.id)
        #expect(runs[0].startedAt == orphan.run.startedAt)
        #expect(runs[0].endedAt == orphan.run.endedAt)
    }

    /// Criterion 5, at the layer that writes the row. The rule is
    /// `AnalysisRunReport.inheritingSentinel(from:)`'s and `ReharvestRuleTests`
    /// holds it; this is the assertion that `reharvest` actually calls it —
    /// re-deriving `false` here is one line away and reads as tidier.
    @Test("A repeat harvest never invents a sentinel reading, and never loses one")
    func reharvestCarriesTheSentinel() async throws {
        let unchecked = try await makeFixture()
        let orphan = try await seedOrphanedRun(unchecked)
        defer { try? FileManager.default.removeItem(at: orphan.artifactURL) }

        let report = try await unchecked.service.reharvest(runID: orphan.run.id)
        #expect(report.kept == 2, "the fixture must actually have harvested something")
        #expect(
            report.workingTreeChanged == nil,
            """
            a repeat harvest claimed a `git status` it never ran. The baseline lived in the \
            scheduler's memory and died with the app — `false` here launders an orphan into a \
            verified-clean run (#39's tri-state, #330 criterion 5)
            """)
        #expect(try await unchecked.store.run(id: orphan.run.id)?
            .analysisReport?.workingTreeChanged == nil)

        // And the other direction: a run that edited the repository must not
        // become clean by being read again.
        let dirty = try await makeFixture()
        let edited = try await seedOrphanedRun(
            dirty,
            report: AnalysisRunReport(
                harvestSource: .none, kept: 0,
                workingTreeChanged: true, workingTreeDiff: " M Sources/Real.swift"
            )
        )
        defer { try? FileManager.default.removeItem(at: edited.artifactURL) }

        let carried = try await dirty.service.reharvest(runID: edited.run.id)
        #expect(carried.workingTreeChanged == true)
        #expect(carried.workingTreeDiff == " M Sources/Real.swift")
    }

    /// Criterion 4. The ids are asserted, not the count: a replace-with-two
    /// would pass a count check while having deleted the rows the reader has
    /// already been deciding on.
    @Test("Harvesting a run that already produced proposals is refused, and changes nothing")
    func reharvestRefusesAnAlreadyHarvestedRun() async throws {
        let fixture = try await makeFixture()
        let orphan = try await seedOrphanedRun(fixture)
        defer { try? FileManager.default.removeItem(at: orphan.artifactURL) }

        _ = try await fixture.service.reharvest(runID: orphan.run.id)
        let first = try await fixture.store.proposals(runID: orphan.run.id)
        #expect(first.count == 2)

        await #expect(throws: AnalysisError.alreadyHarvested) {
            try await fixture.service.reharvest(runID: orphan.run.id)
        }

        let after = try await fixture.store.proposals(runID: orphan.run.id)
        #expect(Set(after.map(\.id)) == Set(first.map(\.id)))
    }

    /// The concurrent half of criterion 4, which the store read alone cannot
    /// close: this actor is reentrant, so two callers can both be past that
    /// read before either writes.
    @Test("Two simultaneous re-harvests land one set of proposals")
    func reharvestRacesToOneSet() async throws {
        let fixture = try await makeFixture()
        let orphan = try await seedOrphanedRun(fixture)
        defer { try? FileManager.default.removeItem(at: orphan.artifactURL) }

        let service = fixture.service
        let runID = orphan.run.id
        let outcomes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    (try? await service.reharvest(runID: runID)) != nil
                }
            }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }

        #expect(outcomes.filter { $0 }.count == 1, "exactly one caller may harvest")
        #expect(try await fixture.store.proposals(runID: runID).count == 2)
    }

    @Test("The refusals name what is wrong")
    func reharvestRefusals() async throws {
        let fixture = try await makeFixture()

        await #expect(throws: AnalysisError.self) {
            try await fixture.service.reharvest(runID: UUID())
        }

        // A card run has no artifact to read.
        let card = try await fixture.board.createCard(repoID: fixture.repo.id, title: "By hand")
        let cardRun = SkillRun.card(
            cardID: card.card.id, repoID: fixture.repo.id, kind: .createIssue,
            prompt: "/create-issue", cwd: "/tmp",
            logPath: "/tmp/a.ndjson", stderrPath: "/tmp/a.log", createdAt: Date()
        )
        try await fixture.store.saveRun(cardRun)
        await #expect(throws: AnalysisError.notAnAnalysisRun) {
            try await fixture.service.reharvest(runID: cardRun.id)
        }

        // A run still in flight will be harvested by `completeAnalysisRun`, and
        // its sentinel baseline is still alive in the scheduler's memory.
        let running = try await seedOrphanedRun(fixture, state: .running)
        defer { try? FileManager.default.removeItem(at: running.artifactURL) }
        await #expect(throws: AnalysisError.runStillRunning) {
            try await fixture.service.reharvest(runID: running.run.id)
        }
    }

    /// The forgotten repository, which is the one refusal that has to happen
    /// *before* anything is written rather than after.
    @Test("A run whose repository has been forgotten is refused, and writes nothing")
    func reharvestRefusesAForgottenRepository() async throws {
        let fixture = try await makeFixture()
        let orphan = try await seedOrphanedRun(fixture)
        defer { try? FileManager.default.removeItem(at: orphan.artifactURL) }
        try await fixture.store.deleteRepo(id: fixture.repo.id)

        await #expect(throws: AnalysisError.self) {
            try await fixture.service.reharvest(runID: orphan.run.id)
        }
    }

    /// Criterion 3 **in failure**, which is the half that is easy to get wrong:
    /// the artifact the sweep deleted is gone, and the honest outcome is a
    /// *replaced* report saying so — not the old one left standing.
    @Test("With the artifact swept away the report is still replaced, and says why")
    func reharvestWithNoArtifactStillReplacesTheReport() async throws {
        let fixture = try await makeFixture()
        let orphan = try await seedOrphanedRun(
            fixture,
            report: AnalysisRunReport(
                harvestSource: .none, dropped: ["Elliot stopped before this run was harvested."])
        )
        try FileManager.default.removeItem(at: orphan.artifactURL)

        let report = try await fixture.service.reharvest(runID: orphan.run.id)

        #expect(report.harvestSource == .none)
        #expect(report.kept == 0)
        #expect(
            report.dropped.contains { $0.contains(orphan.artifactURL.path) },
            "the reader is told which file was not there: \(report.dropped)")
        #expect(
            !report.dropped.contains("Elliot stopped before this run was harvested."),
            "the previous complaint is replaced, not merged")
        #expect(try await fixture.store.proposals(runID: orphan.run.id).isEmpty)
        // Still offered, so a reader who restores the file from a backup can try
        // again rather than being told the recovery has been used up.
        let stored = try #require(try await fixture.store.run(id: orphan.run.id))
        #expect(stored.offersReharvest)
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
