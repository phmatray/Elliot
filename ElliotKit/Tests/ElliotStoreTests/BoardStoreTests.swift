import ElliotModel
import Foundation
import TestSupport
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

    /// `nil` and `[]` must survive the database as different values, because the
    /// whole of #199/#200 is that they are different answers: nobody asked, and
    /// asked-and-chose-nothing. A column that collapsed them would put the
    /// distinction back where it started.
    @Test("A label policy round-trips, and an empty one is not a missing one")
    func labelPolicyRoundTrip() async throws {
        let store = try BoardStore.inMemory()

        let unasked = makeRepo()
        try await store.saveRepo(unasked)
        #expect(try await store.repo(id: unasked.id)?.labelPolicy == nil)

        var chose = makeRepo()
        chose.labelPolicy = [
            RequiredLabel(name: "area: engine", color: "111111", description: "the engine")
        ]
        try await store.saveRepo(chose)
        #expect(try await store.repo(id: chose.id)?.labelPolicy?.count == 1)
        #expect(try await store.repo(id: chose.id)?.labelPolicy?.first?.name == "area: engine")

        var choseNothing = makeRepo()
        choseNothing.labelPolicy = []
        try await store.saveRepo(choseNothing)
        let loaded = try #require(try await store.repo(id: choseNothing.id))
        #expect(loaded.labelPolicy == [], "an empty policy came back as 'nobody asked'")
        #expect(loaded.labelPolicy != nil)
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

    // MARK: - Dismissals, read back and undone one at a time (#334)

    /// Two repositories, each holding the pair a card carrying an issue *and*
    /// its pull request would write.
    private func storeWithDismissals() async throws -> (BoardStore, Repo, Repo) {
        let store = try BoardStore.inMemory()
        let first = makeRepo()
        let second = makeRepo()
        try await store.saveRepo(first)
        try await store.saveRepo(second)
        try await store.dismiss(ExternalRef(kind: .issue, number: 102), repoID: first.id, now: now)
        try await store.dismiss(
            ExternalRef(kind: .pullRequest, number: 201), repoID: first.id, now: now)
        try await store.dismiss(
            ExternalRef(kind: .issue, number: 7), repoID: second.id,
            now: now.addingTimeInterval(60))
        return (store, first, second)
    }

    /// The whole point of the feature at this layer: the timestamp has been in
    /// the table since v5 and `dismissals` threw it away, because its one caller
    /// — the importer — needs only the keys.
    @Test("A dismissal comes back carrying the date it was written with")
    func dismissedItemsCarryTheDateTheKeyThrewAway() async throws {
        let (store, repo) = try await storeWithRepo()
        let ref = ExternalRef(kind: .issue, number: 4)
        try await store.dismiss(ref, repoID: repo.id, now: now)

        let items = try await store.dismissedItems(repoID: repo.id)
        #expect(items.count == 1)
        #expect(items.first?.ref == ref)
        #expect(items.first?.repoID == repo.id)
        #expect(items.first?.dismissedAt == now)
    }

    @Test("nil is every repository; an id is that repository alone")
    func dismissedItemsFollowTheRepositoryArgument() async throws {
        let (store, first, second) = try await storeWithDismissals()
        #expect(try await store.dismissedItems(repoID: nil).count == 3)
        #expect(try await store.dismissedItems(repoID: first.id).count == 2)
        #expect(try await store.dismissedItems(repoID: second.id).map(\.ref.number) == [7])
        #expect(try await store.dismissedItems(repoID: UUID()).isEmpty)
    }

    /// Criterion 2's first half at this layer, and the edge case the face has to
    /// disclose: a card carrying both an issue and its pull request wrote two
    /// rows, and restoring one must leave the other exactly where it is.
    @Test("Undismissing deletes one row, not the card's other ref and not another repository's")
    func undismissDeletesExactlyOneRow() async throws {
        let (store, first, second) = try await storeWithDismissals()

        try await store.undismiss(ExternalRef(kind: .issue, number: 102), repoID: first.id)

        #expect(try await store.dismissals(repoID: first.id)
            == [ExternalRef(kind: .pullRequest, number: 201)])
        #expect(try await store.dismissals(repoID: second.id)
            == [ExternalRef(kind: .issue, number: 7)])
    }

    /// A number matches only under its own kind: issue 5 and PR 5 are two rows,
    /// and a delete keyed on the number alone would take both.
    @Test("Undismissing an issue leaves the pull request that shares its number")
    func undismissIsKeyedOnKindAsWellAsNumber() async throws {
        let (store, repo) = try await storeWithRepo()
        try await store.dismiss(ExternalRef(kind: .issue, number: 5), repoID: repo.id)
        try await store.dismiss(ExternalRef(kind: .pullRequest, number: 5), repoID: repo.id)

        try await store.undismiss(ExternalRef(kind: .issue, number: 5), repoID: repo.id)
        #expect(try await store.dismissals(repoID: repo.id)
            == [ExternalRef(kind: .pullRequest, number: 5)])
    }

    /// The third column of the key, and the one whose absence would be silent:
    /// two repositories very often dismiss the same low issue number, and a
    /// delete that forgot the repository would restore in one board while
    /// quietly restoring in the other.
    @Test("Undismissing in one repository leaves the same number dismissed in another")
    func undismissIsKeyedOnTheRepositoryToo() async throws {
        let store = try BoardStore.inMemory()
        let first = makeRepo()
        let second = makeRepo()
        try await store.saveRepo(first)
        try await store.saveRepo(second)
        let ref = ExternalRef(kind: .issue, number: 12)
        try await store.dismiss(ref, repoID: first.id)
        try await store.dismiss(ref, repoID: second.id)

        try await store.undismiss(ref, repoID: first.id)
        #expect(try await store.dismissals(repoID: first.id).isEmpty)
        #expect(try await store.dismissals(repoID: second.id) == [ref])
    }

    /// Matching `dismiss`'s documented idempotence, from the other side: a row
    /// the next refresh already brought back is a row *Restore* may be pressed
    /// on twice.
    @Test("Undismissing a row that is already gone is a no-op, not an error")
    func undismissingAnAbsentRowIsANoOp() async throws {
        let (store, repo) = try await storeWithRepo()
        try await store.dismiss(ExternalRef(kind: .issue, number: 4), repoID: repo.id)

        try await store.undismiss(ExternalRef(kind: .issue, number: 9), repoID: repo.id)
        try await store.undismiss(ExternalRef(kind: .issue, number: 4), repoID: repo.id)
        try await store.undismiss(ExternalRef(kind: .issue, number: 4), repoID: repo.id)
        #expect(try await store.dismissals(repoID: repo.id).isEmpty)
    }

    /// The importer's view is now a *projection* of the reader's, not a second
    /// SELECT over the same table. Asserted on a fixture where the two could
    /// disagree — two repositories, and a repository holding two kinds.
    @Test("The importer's key set is exactly the reader's rows, mapped down")
    func dismissalsIsAProjectionOfDismissedItems() async throws {
        let (store, first, second) = try await storeWithDismissals()
        for repo in [first, second] {
            let keys = try await store.dismissals(repoID: repo.id)
            let rows = try await store.dismissedItems(repoID: repo.id)
            #expect(keys == Set(rows.map(\.ref)))
        }
    }

    /// Criterion 4 at this layer: *Forget dismissed items* keeps clearing them
    /// all — and keeps meaning "this repository", not "the table".
    @Test("Forgetting one repository's dismissals leaves the other repository's alone")
    func clearDismissalsStillEmptiesOneRepository() async throws {
        let (store, first, second) = try await storeWithDismissals()
        try await store.clearDismissals(repoID: first.id)
        #expect(try await store.dismissedItems(repoID: first.id).isEmpty)
        #expect(try await store.dismissedItems(repoID: second.id).count == 1)
    }

    /// The figure in the status bar is driven by this rather than by the last
    /// import summary, so a restore decrements it immediately and a stale count
    /// cannot outlive the fact it reports.
    @Test("The table is observable, so the figure follows a restore rather than a refresh")
    func observeDismissalsDeliversTheTable() async throws {
        let (store, _, _) = try await storeWithDismissals()
        let delivered = try await withTimeout(.seconds(5)) {
            for try await rows in store.observeDismissals() { return rows }
            return [DismissedItem]()
        }
        #expect(delivered.count == 3)
        #expect(Set(delivered.map(\.ref.number)) == [102, 201, 7])
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
