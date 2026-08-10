import ElliotModel
import ElliotStore
import Foundation
import Testing

/// The two narrow writes an appraisal needs, and the reason neither is
/// `saveCard`.
@Suite("Appraisal writes")
struct AppraisalStoreTests {

    private struct Seeded {
        var store: BoardStore
        var repo: Repo
        var card: Card
    }

    private func seed() async throws -> Seeded {
        let store = try BoardStore.inMemory()
        let repo = Repo(path: "/tmp/r", nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        try await store.saveRepo(repo)
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        let card = Card(
            repoID: repo.id, title: "A story", columnEnteredAt: now,
            createdAt: now, updatedAt: now
        )
        try await store.saveCard(card)
        return Seeded(store: store, repo: repo, card: card)
    }

    private func run(_ seeded: Seeded, kind: SkillKind, state: RunState) -> SkillRun {
        var run = SkillRun.card(
            cardID: seeded.card.id, repoID: seeded.repo.id, kind: kind, prompt: "x",
            cwd: seeded.repo.path, logPath: "/tmp/a.ndjson", stderrPath: "/tmp/a.log",
            createdAt: Date()
        )
        run.state = state
        return run
    }

    @Test("An appraisal writes exactly three fields")
    func appraisalWritesThreeFields() async throws {
        let seeded = try await seed()
        let at = Date(timeIntervalSince1970: 1_770_000_500)

        let written = try #require(
            try await seeded.store.applyAppraisal(
                cardID: seeded.card.id, effort: .large,
                evidence: [Evidence(path: "a.swift", line: 3, exists: true)], at: at
            )
        )
        #expect(written.effort == .large)
        #expect(written.evidence?.count == 1)
        #expect(written.appraisedAt == at)
        // And nothing else moved.
        #expect(written.column == seeded.card.column)
        #expect(written.title == seeded.card.title)
        #expect(written.issueNumber == nil)
    }

    /// The write window, in the direction that loses the **column**.
    @Test("A move committed before the appraisal is not overwritten by it")
    func appraisalDoesNotCarryAStaleColumnBack() async throws {
        let seeded = try await seed()

        // The harvester's read happens here, in the real ordering: the card is
        // read, the run finishes, and the write comes later.
        let readEarly = try #require(try await seeded.store.card(id: seeded.card.id))
        #expect(readEarly.column == .backlog)

        // A move lands in between, writing the whole row from its own snapshot.
        try await seeded.store.commitMove(
            card: readEarly, to: .todo, orderIndex: 2048,
            origin: .userDrag, run: nil
        )

        // The appraisal is written by id, not by handing back `readEarly`.
        try await seeded.store.applyAppraisal(
            cardID: seeded.card.id, effort: .small, evidence: [], at: Date()
        )

        let after = try #require(try await seeded.store.card(id: seeded.card.id))
        #expect(after.column == .todo)        // the move survived
        #expect(after.effort == .small)       // and so did the appraisal
        #expect(after.appraisedAt != nil)
    }

    /// `applyAppraisal` reads and writes inside one transaction, so a value it
    /// read before the write cannot be the value it writes back.
    ///
    /// This is deliberately not a `commitMove`-interleaving test: a stale
    /// `Card` handed to `commitMove` after an appraisal lands is a real gap
    /// (see the store's own doc comment on `applyAppraisal`), but it is a gap
    /// in `commitMove`'s "write a whole card" contract, not in this method.
    /// Pinning it here, against this method, would pass regardless of whether
    /// `applyAppraisal` is transactional at all — and it would start failing
    /// the day `commitMove` is narrowed, which is the actual fix, punishing
    /// the repair this test exists to protect against. What this task adds is
    /// the read-modify-write on the three appraisal columns; that is what
    /// gets pinned.
    @Test("Two appraisals racing the same card do not clobber each other's other fields")
    func applyAppraisalReadsAndWritesInOneTransaction() async throws {
        let seeded = try await seed()

        // First appraisal lands.
        try await seeded.store.applyAppraisal(
            cardID: seeded.card.id, effort: .medium,
            evidence: [Evidence(path: "a.swift", line: 1, exists: true)],
            at: Date(timeIntervalSince1970: 1_770_000_100)
        )

        // A second appraisal — a re-run of the same lens, say — reads and
        // writes afresh rather than carrying the first call's in-memory
        // snapshot forward. Because the method itself does the reading, there
        // is no caller-held `Card` to go stale in between.
        let second = try #require(
            try await seeded.store.applyAppraisal(
                cardID: seeded.card.id, effort: .large,
                evidence: [Evidence(path: "b.swift", line: 9, exists: false)],
                at: Date(timeIntervalSince1970: 1_770_000_200)
            )
        )

        #expect(second.effort == .large)
        #expect(second.evidence?.map(\.path) == ["b.swift"])

        let after = try #require(try await seeded.store.card(id: seeded.card.id))
        #expect(after.effort == .large)
        #expect(after.evidence?.map(\.path) == ["b.swift"])
        #expect(after.appraisedAt == Date(timeIntervalSince1970: 1_770_000_200))
    }

    @Test("Appraising a card that has been deleted answers nil rather than throwing")
    func deletedCardIsNotAnError() async throws {
        let seeded = try await seed()
        try await seeded.store.deleteCard(id: seeded.card.id)
        #expect(
            try await seeded.store.applyAppraisal(
                cardID: seeded.card.id, effort: .small, evidence: [], at: Date()
            ) == nil
        )
    }

    @Test("The first claim on a free card wins, and it is then the active run")
    func firstClaimWins() async throws {
        let seeded = try await seed()
        let first = run(seeded, kind: .appraiseCards, state: .queued)
        #expect(try await seeded.store.claimCardForRun(first))
        #expect(try await seeded.store.activeRun(cardID: seeded.card.id)?.id == first.id)
    }

    @Test("A second claim on a held card is refused, and inserts nothing")
    func secondClaimIsRefused() async throws {
        let seeded = try await seed()
        let first = run(seeded, kind: .appraiseCards, state: .running)
        #expect(try await seeded.store.claimCardForRun(first))

        let second = run(seeded, kind: .appraiseCards, state: .queued)
        #expect(try await seeded.store.claimCardForRun(second) == false)
        #expect(try await seeded.store.run(id: second.id) == nil)
        #expect(try await seeded.store.runs(cardID: seeded.card.id).count == 1)
    }

    @Test("Any active run holds the card, not only another appraisal")
    func anyActiveRunHoldsTheCard() async throws {
        let seeded = try await seed()
        let writer = run(seeded, kind: .implementIssue, state: .running)
        try await seeded.store.saveRun(writer)
        #expect(try await seeded.store.claimCardForRun(
            run(seeded, kind: .appraiseCards, state: .queued)) == false)
    }

    @Test("A finished run does not hold the card")
    func aTerminalRunReleasesTheCard() async throws {
        let seeded = try await seed()
        var done = run(seeded, kind: .appraiseCards, state: .succeeded)
        done.endedAt = Date()
        try await seeded.store.saveRun(done)
        #expect(try await seeded.store.claimCardForRun(
            run(seeded, kind: .appraiseCards, state: .queued)))
    }

    @Test("A run with no card cannot claim one")
    func aCardlessRunIsRefused() async throws {
        let seeded = try await seed()
        let analysis = Analysis(repoID: seeded.repo.id, angles: [.bugs], createdAt: Date())
        try await seeded.store.saveAnalysis(analysis)
        let run = SkillRun.analysis(
            repoID: seeded.repo.id, analysisID: analysis.id, analysisAngle: .bugs,
            prompt: "x", cwd: seeded.repo.path, logPath: "/tmp/a", stderrPath: "/tmp/b",
            createdAt: Date()
        )
        #expect(try await seeded.store.claimCardForRun(run) == false)
    }
}
