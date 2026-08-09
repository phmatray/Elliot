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
    SkillRun.card(
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

    /// The sweep's write is the hazard, not the fix, so both are asserted here.
    ///
    /// `AppModel.refreshRepoChecks` captures a `Repo`, awaits a networked
    /// `gh`/`git` sweep for seconds, then writes the captured row back. If that
    /// write-back carries the whole row, a run-terms change made during the
    /// window is silently reverted — and the field being reverted is the one
    /// bounding what an unattended agent may do to the checkout.
    @Test("Preflight's verdict is written without carrying the rest of the row")
    func verdictWriteIsTargeted() async throws {
        let store = try BoardStore.inMemory()
        let repo = makeRepo()
        try await store.saveRepo(repo)
        let staleCopy = try #require(try await store.repo(id: repo.id))

        // The reader tightens the repository while the sweep is in flight.
        var tightened = staleCopy
        tightened.permissionMode = .plan
        tightened.extraAllowedTools = ["Read"]
        try await store.saveRepo(tightened)

        // The sweep lands, holding the row it captured before the change.
        try await store.saveRepoPreflight(id: staleCopy.id, verdict: .passing)

        let after = try #require(try await store.repo(id: repo.id))
        #expect(after.preflight == .passing)
        #expect(after.permissionMode == .plan, "the sweep reverted the mode")
        #expect(after.extraAllowedTools == ["Read"], "the sweep reverted the tools")
    }

    /// The same sequence through the write this replaces, so the test names what
    /// goes wrong rather than only asserting that it no longer does. If this
    /// ever passes, `saveRepo` has quietly become targeted and the method above
    /// has lost its reason to exist.
    @Test("A whole-row write-back from a stale copy is what loses the setting")
    func wholeRowWriteBackRevertsTheSetting() async throws {
        let store = try BoardStore.inMemory()
        let repo = makeRepo()
        try await store.saveRepo(repo)
        var staleCopy = try #require(try await store.repo(id: repo.id))

        var tightened = staleCopy
        tightened.permissionMode = .plan
        try await store.saveRepo(tightened)

        staleCopy.preflight = .passing
        try await store.saveRepo(staleCopy)

        let after = try #require(try await store.repo(id: repo.id))
        #expect(after.preflight == .passing)
        #expect(after.permissionMode == .bypassPermissions, "the hazard has changed shape")
    }

    @Test("Writing a verdict for a repository that is gone changes nothing and does not throw")
    func verdictWriteForAnAbsentRepoIsQuiet() async throws {
        let store = try BoardStore.inMemory()
        try await store.saveRepoPreflight(id: UUID(), verdict: .failing)
        #expect(try await store.repos().isEmpty)
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

@Suite("GitHub import persistence")
struct ImportPersistenceTests {

    private func storeWithRepo() async throws -> (BoardStore, Repo) {
        let store = try BoardStore.inMemory()
        let repo = Repo(path: "/tmp/elliot", nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        try await store.saveRepo(repo)
        return (store, repo)
    }

    private func card(_ repo: Repo, issueNumber: Int? = nil, prNumber: Int? = nil) -> Card {
        let t = Date(timeIntervalSince1970: 0)
        return Card(
            repoID: repo.id, title: "work", issueNumber: issueNumber, prNumber: prNumber,
            columnEnteredAt: t, createdAt: t, updatedAt: t)
    }

    @Test("Two cards cannot claim the same issue in one repository")
    func duplicateIssueNumberIsRejected() async throws {
        let (store, repo) = try await storeWithRepo()
        try await store.saveCard(card(repo, issueNumber: 11))
        await #expect(throws: (any Error).self) {
            try await store.saveCard(card(repo, issueNumber: 11))
        }
    }

    @Test("Two cards cannot claim the same pull request in one repository")
    func duplicatePRNumberIsRejected() async throws {
        let (store, repo) = try await storeWithRepo()
        try await store.saveCard(card(repo, prNumber: 20))
        await #expect(throws: (any Error).self) {
            try await store.saveCard(card(repo, prNumber: 20))
        }
    }

    @Test("Many cards may carry no issue at all")
    func nullsDoNotCollide() async throws {
        let (store, repo) = try await storeWithRepo()
        try await store.saveCard(card(repo))
        try await store.saveCard(card(repo))
        #expect(try await store.cards(repoID: repo.id).count == 2)
    }

    @Test("Dismissals round-trip")
    func dismissalsRoundTrip() async throws {
        let (store, repo) = try await storeWithRepo()
        let ref = ExternalRef(kind: .issue, number: 4)
        try await store.dismiss(ref, repoID: repo.id)
        #expect(try await store.dismissals(repoID: repo.id) == [ref])
        // Dismissing twice is not an error — the user may delete a resurrected card.
        try await store.dismiss(ref, repoID: repo.id)
        #expect(try await store.dismissals(repoID: repo.id).count == 1)
        try await store.clearDismissals(repoID: repo.id)
        #expect(try await store.dismissals(repoID: repo.id).isEmpty)
    }

    @Test("Dismissals die with their repository")
    func dismissalsCascade() async throws {
        let (store, repo) = try await storeWithRepo()
        try await store.dismiss(ExternalRef(kind: .pullRequest, number: 20), repoID: repo.id)
        try await store.deleteRepo(id: repo.id)
        #expect(try await store.dismissals(repoID: repo.id).isEmpty)
    }

    /// Reopening is the everyday path; the upgrade *over pre-existing rows* —
    /// which is the one that can actually fail — is proven in
    /// `SchemaUpgradeTests`, over a file rewound to v1 on purpose.
    @Test("Reopening a store runs every migration and keeps its cards")
    func migrationIsAdditive() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elliot-v1-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try BoardStore.open(at: url)
        let repo = Repo(path: "/tmp/elliot", nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        try await first.saveRepo(repo)
        try await first.saveCard(card(repo, issueNumber: 11))

        // Reopening runs every registered migration against the existing file.
        let second = try BoardStore.open(at: url)
        #expect(try await second.cards(repoID: repo.id).count == 1)
        #expect(try await second.dismissals(repoID: repo.id).isEmpty)
    }
}
