import ElliotModel
import ElliotStore
import Foundation
import TestSupport
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

    /// Two sequential calls can never observe a race — the second one only
    /// starts after the first has fully returned — so asserting on them says
    /// nothing about whether the read and the write inside `applyAppraisal`
    /// share one transaction. Kept anyway because it pins a real, separate
    /// fact the race test below does not: a later call's fields fully replace
    /// an earlier call's, rather than merging with them field-by-field.
    @Test("A second appraisal replaces the first's fields rather than merging with them")
    func aLaterAppraisalReplacesTheEarlierOnesFields() async throws {
        let seeded = try await seed()

        try await seeded.store.applyAppraisal(
            cardID: seeded.card.id, effort: .medium,
            evidence: [Evidence(path: "a.swift", line: 1, exists: true)],
            at: Date(timeIntervalSince1970: 1_770_000_100)
        )

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

    /// Fires many `applyAppraisal` calls at the same card concurrently, each
    /// carrying a triple only it could have produced, and checks that
    /// whichever one survives is internally whole rather than a mix of two
    /// calls' fields.
    ///
    /// ⚠️ **This does not prove `applyAppraisal` is transactional, and it is
    /// not capable of proving it.** Measured directly: split `applyAppraisal`
    /// into a `reader.read`, a real suspension, and a separate
    /// `requireWriter().write` — including a variant with an explicit 20ms
    /// sleep after the read to force every task's read to land before any
    /// task's write — and this exact test still passed, across eight runs.
    /// The reason is structural rather than a scheduling accident a slower
    /// machine might still expose: every call, split or not, assembles its
    /// own effort/evidence/appraisedAt into one local `Card` value before it
    /// ever reaches `.update(db)`, and that single call persists the whole
    /// value in one `UPDATE` statement. Two concurrent calls can therefore
    /// only ever race to be the *last commit* — never interleave field by
    /// field — so whichever one lands is always whole, transactional or not.
    /// A race that can't produce the failure it's named for isn't proving the
    /// property; it's exercising a scenario the property was never at risk
    /// in.
    ///
    /// It is kept anyway for what it *does* show: concurrent appraisal
    /// traffic against one card cannot corrupt it into an inconsistent row,
    /// whichever call happens to win. That's real, just narrower than
    /// "transactional" — the actual one-transaction claim is pinned in
    /// `AppraisalTransactionShapeTests`, which reads the source the way
    /// `RunSchedulerShapeTests` already does in this codebase for exactly
    /// this situation: a property a race test cannot observe.
    ///
    /// Deliberately not asserting *which* call wins — that depends on
    /// scheduling and asserting it would make the test flaky.
    @Test("Concurrent appraisals of one card never settle on a mixed triple")
    func concurrentAppraisalsNeverSettleOnAMixedTriple() async throws {
        let seeded = try await seed()
        let base = Date(timeIntervalSince1970: 1_770_000_000)
        let efforts = Effort.allCases
        let concurrency = 20

        @Sendable func triple(for index: Int) -> (Effort, [Evidence], Date) {
            (
                efforts[index % efforts.count],
                [Evidence(path: "call-\(index).swift", line: index, exists: index.isMultiple(of: 2))],
                base.addingTimeInterval(Double(index))
            )
        }

        try await withTimeout {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<concurrency {
                    group.addTask {
                        let (effort, evidence, at) = triple(for: index)
                        try await seeded.store.applyAppraisal(
                            cardID: seeded.card.id, effort: effort, evidence: evidence, at: at
                        )
                    }
                }
                for try await _ in group {}
            }
        }

        let settled = try #require(try await seeded.store.card(id: seeded.card.id))
        let winner = try #require(settled.evidence?.first)
        let index = winner.line!
        let (expectedEffort, expectedEvidence, expectedAt) = triple(for: index)

        #expect(settled.effort == expectedEffort, "effort did not come from the same call as evidence")
        #expect(settled.evidence == expectedEvidence)
        #expect(
            settled.appraisedAt == expectedAt,
            "appraisedAt did not come from the same call as evidence"
        )
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
