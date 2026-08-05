import ElliotModel
import Foundation
import Testing

@testable import ElliotStore

private let now = Date(timeIntervalSince1970: 1_700_000_000)

private func makeRepo() -> Repo {
    Repo(path: "/tmp/repo-\(UUID().uuidString)", nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
}

private func makeCard(repoID: UUID, column: Column = .backlog, orderIndex: Double = 0) -> Card {
    Card(
        repoID: repoID,
        title: "Run log",
        column: column,
        orderIndex: orderIndex,
        columnEnteredAt: now,
        createdAt: now,
        updatedAt: now
    )
}

private func makeRun(cardID: UUID, repoID: UUID, state: RunState = .queued) -> SkillRun {
    SkillRun(
        cardID: cardID,
        repoID: repoID,
        kind: .createIssue,
        prompt: "/ai-migration-kit:create-issue something",
        argv: ["claude", "-p", "…"],
        cwd: "/tmp/repo",
        state: state,
        logPath: "/tmp/log.ndjson",
        stderrPath: "/tmp/log.stderr.log",
        createdAt: now
    )
}

@Suite("Board store")
struct BoardStoreTests {

    @Test("Migrations run against an empty database")
    func migrations() throws {
        _ = try BoardStore.inMemory()
    }

    @Test("A repo round-trips")
    func repoRoundTrip() async throws {
        let store = try BoardStore.inMemory()
        var repo = makeRepo()
        repo.permissionMode = .bypassPermissions
        repo.extraAllowedTools = ["Bash(git status *)", "Read"]
        try await store.saveRepo(repo)

        let loaded = try await store.repo(id: repo.id)
        #expect(loaded == repo)
        #expect(loaded?.extraAllowedTools == ["Bash(git status *)", "Read"])
        #expect(try await store.repo(path: repo.path) == repo)
    }

    @Test("A card carrying a user story round-trips, story and all")
    func cardWithStoryRoundTrip() async throws {
        let store = try BoardStore.inMemory()
        let repo = makeRepo()
        try await store.saveRepo(repo)

        var card = makeCard(repoID: repo.id)
        card.story = UserStory(
            role: "developer",
            want: "to see the run log inside the card",
            benefit: "I can diagnose without a terminal",
            acceptanceCriteria: ["streams live", "survives a relaunch"]
        )
        card.issueNumber = 47
        card.issueURL = "https://github.com/phmatray/Elliot/issues/47"
        try await store.saveCard(card)

        let loaded = try #require(try await store.card(id: card.id))
        #expect(loaded.story == card.story)
        #expect(loaded.story?.acceptanceCriteria.count == 2)
        #expect(loaded.issueNumber == 47)
    }

    @Test("A card with no story stores null rather than an empty object")
    func cardWithoutStory() async throws {
        let store = try BoardStore.inMemory()
        let repo = makeRepo()
        try await store.saveRepo(repo)
        let card = makeCard(repoID: repo.id)
        try await store.saveCard(card)
        #expect(try await store.card(id: card.id)?.story == nil)
    }

    @Test("Cards are listed per repo and per column, in order")
    func cardQuerying() async throws {
        let store = try BoardStore.inMemory()
        let a = makeRepo(), b = makeRepo()
        try await store.saveRepo(a)
        try await store.saveRepo(b)

        try await store.saveCard(makeCard(repoID: a.id, column: .backlog, orderIndex: 20))
        try await store.saveCard(makeCard(repoID: a.id, column: .backlog, orderIndex: 10))
        try await store.saveCard(makeCard(repoID: a.id, column: .todo, orderIndex: 5))
        try await store.saveCard(makeCard(repoID: b.id, column: .backlog, orderIndex: 1))

        #expect(try await store.cards(repoID: a.id).count == 3)
        let backlog = try await store.cards(repoID: a.id, column: .backlog)
        #expect(backlog.map(\.orderIndex) == [10, 20])
        #expect(try await store.cards(repoID: b.id).count == 1)
        #expect(try await store.cards().count == 4)
    }

    @Test("The next order index lands below everything in the column")
    func nextOrderIndex() async throws {
        let store = try BoardStore.inMemory()
        let repo = makeRepo()
        try await store.saveRepo(repo)

        #expect(try await store.nextOrderIndex(repoID: repo.id, column: .backlog) == 1024)
        try await store.saveCard(makeCard(repoID: repo.id, column: .backlog, orderIndex: 5000))
        #expect(try await store.nextOrderIndex(repoID: repo.id, column: .backlog) == 6024)
        // A different column is unaffected.
        #expect(try await store.nextOrderIndex(repoID: repo.id, column: .todo) == 1024)
    }

    // MARK: - The compound write

    @Test("A triggering move writes the card, the run and the audit together")
    func commitMoveWritesAllThree() async throws {
        let store = try BoardStore.inMemory()
        let repo = makeRepo()
        try await store.saveRepo(repo)
        let card = makeCard(repoID: repo.id)
        try await store.saveCard(card)

        let run = makeRun(cardID: card.id, repoID: repo.id)
        try await store.commitMove(
            card: card, to: .todo, orderIndex: 1024,
            origin: .userDrag, run: run, now: now
        )

        let moved = try #require(try await store.card(id: card.id))
        #expect(moved.column == .todo)
        #expect(moved.orderIndex == 1024)
        #expect(moved.columnEnteredAt == now)

        #expect(try await store.run(id: run.id)?.state == .queued)

        let audits = try await store.audits(cardID: card.id)
        #expect(audits.count == 1)
        #expect(audits[0].from == .backlog)
        #expect(audits[0].to == .todo)
        #expect(audits[0].origin == .userDrag)
        #expect(audits[0].runID == run.id)
    }

    @Test("An inert move is still audited, with no run attached")
    func commitMoveWithoutRun() async throws {
        let store = try BoardStore.inMemory()
        let repo = makeRepo()
        try await store.saveRepo(repo)
        let card = makeCard(repoID: repo.id, column: .inProgress)
        try await store.saveCard(card)

        try await store.commitMove(
            card: card, to: .inReview, orderIndex: 1,
            origin: .system(reason: .prBecameReady), run: nil, now: now
        )

        #expect(try await store.card(id: card.id)?.column == .inReview)
        #expect(try await store.runs(cardID: card.id).isEmpty)
        let audits = try await store.audits(cardID: card.id)
        #expect(audits[0].origin == .system(reason: .prBecameReady))
        #expect(audits[0].runID == nil)
    }

    @Test("A failing compound write leaves nothing behind")
    func commitMoveIsAtomic() async throws {
        let store = try BoardStore.inMemory()
        let repo = makeRepo()
        try await store.saveRepo(repo)
        let card = makeCard(repoID: repo.id)
        try await store.saveCard(card)

        // A run pointing at a card that does not exist violates the foreign
        // key, so the insert fails after the card update has been staged.
        let bogus = makeRun(cardID: UUID(), repoID: repo.id)
        await #expect(throws: (any Error).self) {
            try await store.commitMove(
                card: card, to: .todo, orderIndex: 1024,
                origin: .userDrag, run: bogus, now: now
            )
        }

        // The card must not have moved, and no audit may survive.
        #expect(try await store.card(id: card.id)?.column == .backlog)
        #expect(try await store.audits(cardID: card.id).isEmpty)
    }

    // MARK: - Runs

    @Test("The active run of a card is found, and terminal runs are ignored")
    func activeRun() async throws {
        let store = try BoardStore.inMemory()
        let repo = makeRepo()
        try await store.saveRepo(repo)
        let card = makeCard(repoID: repo.id)
        try await store.saveCard(card)

        #expect(try await store.activeRun(cardID: card.id) == nil)

        var finished = makeRun(cardID: card.id, repoID: repo.id, state: .succeeded)
        finished.verifiedOutcome = .issueCreated(number: 47, url: "https://example.com/47")
        try await store.saveRun(finished)
        #expect(try await store.activeRun(cardID: card.id) == nil)

        let live = makeRun(cardID: card.id, repoID: repo.id, state: .running)
        try await store.saveRun(live)
        #expect(try await store.activeRun(cardID: card.id)?.id == live.id)

        // A verified outcome with associated values survives the round trip.
        let reloaded = try #require(try await store.run(id: finished.id))
        #expect(reloaded.verifiedOutcome == .issueCreated(number: 47, url: "https://example.com/47"))
    }

    @Test("A stalled run still holds its card")
    func stalledRunIsActive() async throws {
        let store = try BoardStore.inMemory()
        let repo = makeRepo()
        try await store.saveRepo(repo)
        let card = makeCard(repoID: repo.id)
        try await store.saveCard(card)
        try await store.saveRun(makeRun(cardID: card.id, repoID: repo.id, state: .stalled))
        #expect(try await store.activeRun(cardID: card.id) != nil)
    }

    @Test("The launch sweep sees every run that was mid-flight")
    func nonTerminalRuns() async throws {
        let store = try BoardStore.inMemory()
        let repo = makeRepo()
        try await store.saveRepo(repo)
        let card = makeCard(repoID: repo.id)
        try await store.saveCard(card)

        for state in RunState.allCases {
            try await store.saveRun(makeRun(cardID: card.id, repoID: repo.id, state: state))
        }
        let sweep = try await store.nonTerminalRuns()
        #expect(Set(sweep.map(\.state)) == Set(RunState.allCases.filter(\.isActive)))
    }

    // MARK: - Read-only

    @Test("A read-only store answers reads and refuses writes")
    func readOnlyStore() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elliot-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("elliot.sqlite")

        let writable = try BoardStore.open(at: dbURL)
        let repo = makeRepo()
        try await writable.saveRepo(repo)
        try await writable.saveCard(makeCard(repoID: repo.id))

        let readOnly = try BoardStore.openReadOnly(at: dbURL)
        #expect(!readOnly.isWritable)
        #expect(try await readOnly.cards().count == 1)
        await #expect(throws: StoreError.readOnly) {
            try await readOnly.saveCard(makeCard(repoID: repo.id))
        }
    }

    @Test("Deleting a repo takes its cards with it")
    func cascadingDelete() async throws {
        let store = try BoardStore.inMemory()
        let repo = makeRepo()
        try await store.saveRepo(repo)
        let card = makeCard(repoID: repo.id)
        try await store.saveCard(card)
        try await store.saveRun(makeRun(cardID: card.id, repoID: repo.id))

        try await store.deleteRepo(id: repo.id)
        #expect(try await store.cards().isEmpty)
        #expect(try await store.runs().isEmpty)
    }

    @Test("The tree layout round-trips through the settings table")
    func layoutRoundTrip() async throws {
        let store = try BoardStore.inMemory()
        #expect(try await store.layout() == nil)

        let layout = RepoTreeLayout(root: "/R", owners: ["phmatray", "Atypical-Consulting"])
        try await store.saveLayout(layout)
        #expect(try await store.layout() == layout)

        try await store.saveLayout(RepoTreeLayout(root: "/S", owners: ["phmatray"]))
        #expect(try await store.layout()?.root == "/S", "saving replaces rather than appends")
    }

    @Test("A repo's visibility round-trips and defaults to nil")
    func repoVisibility() async throws {
        let store = try BoardStore.inMemory()
        var repo = makeRepo()
        #expect(repo.visibility == nil)
        repo.visibility = .private
        try await store.saveRepo(repo)
        #expect(try await store.repo(id: repo.id)?.visibility == .private)
    }
}
