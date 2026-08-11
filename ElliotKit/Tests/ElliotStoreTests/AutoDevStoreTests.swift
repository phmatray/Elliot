import ElliotModel
import Foundation
import Testing

@testable import ElliotStore

@Suite("Auto-dev store")
struct AutoDevStoreTests {

    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    private func seeded() async throws -> (BoardStore, Repo, [Card]) {
        let store = try BoardStore.inMemory()
        let repo = Repo(
            path: "/tmp/repo-\(UUID().uuidString)", nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot"
        )
        try await store.saveRepo(repo)
        var cards: [Card] = []
        for index in 0..<3 {
            let card = Card(
                repoID: repo.id, title: "Card \(index)",
                columnEnteredAt: epoch, createdAt: epoch, updatedAt: epoch
            )
            try await store.saveCard(card)
            cards.append(card)
        }
        return (store, repo, cards)
    }

    @Test("A session and its rows land in one transaction, and read back whole")
    func sessionAndRowsRoundTrip() async throws {
        let (store, repo, cards) = try await seeded()
        let session = AutoDevSession(
            repoID: repo.id, engagedCardIDs: cards.map(\.id), maxAttemptsPerCard: 2,
            patience: 900, startedAt: epoch
        )
        let rows = cards.map {
            AutoDevEngagement(
                sessionID: session.id, cardID: $0.id, attempts: 0,
                disposition: .engaged, reason: "Not started.", updatedAt: epoch)
        }
        try await store.saveAutoDevSession(session, cards: rows)

        let readBack = try #require(try await store.autoDevSession(id: session.id))
        #expect(readBack.engagedCardIDs == cards.map(\.id))
        #expect(readBack.patience == 900)
        #expect(readBack.state == .running)

        let readRows = try await store.autoDevEngagements(sessionID: session.id)
        #expect(readRows.count == 3)
        // The closed list and the mutable rows describe the same set. They are
        // two representations on purpose — the array is the promise, the rows
        // are the state — so this is the assertion that keeps them agreed.
        #expect(Set(readRows.map(\.cardID)) == Set(readBack.engagedCardIDs))
    }

    @Test("A session whose rows cannot be written writes nothing at all")
    func theTransactionIsOne() async throws {
        let (store, repo, cards) = try await seeded()
        let session = AutoDevSession(
            repoID: repo.id, engagedCardIDs: cards.map(\.id), maxAttemptsPerCard: 2,
            patience: 900, startedAt: epoch
        )
        // A row naming a card that does not exist: the foreign key fails, and
        // the session must not survive it. Otherwise a crash between two writes
        // leaves a session with fewer cards than it was started with, and
        // nothing walks the one against the other to notice.
        let rows = [
            AutoDevEngagement(
                sessionID: session.id, cardID: cards[0].id, attempts: 0,
                disposition: .engaged, reason: "", updatedAt: epoch),
            AutoDevEngagement(
                sessionID: session.id, cardID: UUID(), attempts: 0,
                disposition: .engaged, reason: "", updatedAt: epoch),
        ]
        await #expect(throws: (any Error).self) {
            try await store.saveAutoDevSession(session, cards: rows)
        }
        #expect(try await store.autoDevSession(id: session.id) == nil)
    }

    @Test("Only running sessions are resumed")
    func runningSessionsAreFiltered() async throws {
        let (store, repo, cards) = try await seeded()
        let live = AutoDevSession(
            repoID: repo.id, engagedCardIDs: [cards[0].id], maxAttemptsPerCard: 1,
            patience: 60, startedAt: epoch)
        var done = AutoDevSession(
            repoID: repo.id, engagedCardIDs: [cards[1].id], maxAttemptsPerCard: 1,
            patience: 60, startedAt: epoch)
        done.state = .finished
        done.endedAt = epoch
        try await store.saveAutoDevSession(live, cards: [])
        try await store.saveAutoDevSession(done, cards: [])

        let running = try await store.runningAutoDevSessions()
        #expect(running.map(\.id) == [live.id])
    }

    @Test("A run remembers the rule the move that made it demanded")
    func runCarriesTheFlag() async throws {
        let (store, repo, cards) = try await seeded()
        var run = SkillRun.card(
            cardID: cards[0].id, repoID: repo.id, kind: .mergePR, prompt: "x",
            cwd: repo.path, logPath: "/tmp/a", stderrPath: "/tmp/b", createdAt: epoch
        )
        run.requiresVerifiedGreen = true
        try await store.saveRun(run)

        let readBack = try #require(try await store.run(id: run.id))
        #expect(readBack.demandsVerifiedGreen)

        // And the absent value is the answer for every run that predates the rule.
        let plain = SkillRun.card(
            cardID: cards[1].id, repoID: repo.id, kind: .mergePR, prompt: "x",
            cwd: repo.path, logPath: "/tmp/a", stderrPath: "/tmp/b", createdAt: epoch
        )
        try await store.saveRun(plain)
        #expect(try await store.run(id: plain.id)?.demandsVerifiedGreen == false)
    }

    @Test("Updating one card's row leaves the others alone")
    func rowsAreIndependent() async throws {
        let (store, repo, cards) = try await seeded()
        let session = AutoDevSession(
            repoID: repo.id, engagedCardIDs: cards.map(\.id), maxAttemptsPerCard: 2,
            patience: 900, startedAt: epoch)
        let rows = cards.map {
            AutoDevEngagement(
                sessionID: session.id, cardID: $0.id, attempts: 0,
                disposition: .engaged, reason: "Not started.", updatedAt: epoch)
        }
        try await store.saveAutoDevSession(session, cards: rows)

        var first = rows[0]
        first.attempts = 2
        first.disposition = .merged
        first.reason = "Merged."
        first.updatedAt = epoch.addingTimeInterval(60)
        try await store.saveAutoDevEngagement(first)

        let readRows = try await store.autoDevEngagements(sessionID: session.id)
        let settled = readRows.filter(\.isSettled)
        #expect(settled.count == 1)
        #expect(settled.first?.attempts == 2)
        #expect(readRows.count == 3)
    }

    // ⛔ Pinned per Task 5's brief §4: `AutoDevEngagement.id` is a computed
    // `{ cardID }`, not a column — the row's real key is `(sessionID, cardID)`.
    // Two sessions engaging the same card is not a corner case; it is the
    // second session a reader starts. A lookup that leaned on `id` (or on
    // `filter(id:)`, which GRDB hangs off the primary key) would confuse the
    // two sessions' rows for the same card. This test fails loudly if
    // `autoDevEngagements(sessionID:)` or the composite primary key ever stop
    // keeping them apart.
    @Test("Two sessions engaging the same card keep separate rows")
    func sameCardTwoSessionsStaySeparate() async throws {
        let (store, repo, cards) = try await seeded()
        let sessionA = AutoDevSession(
            repoID: repo.id, engagedCardIDs: [cards[0].id], maxAttemptsPerCard: 2,
            patience: 900, startedAt: epoch)
        let sessionB = AutoDevSession(
            repoID: repo.id, engagedCardIDs: [cards[0].id], maxAttemptsPerCard: 2,
            patience: 900, startedAt: epoch.addingTimeInterval(3600))
        let rowA = AutoDevEngagement(
            sessionID: sessionA.id, cardID: cards[0].id, attempts: 1,
            disposition: .engaged, reason: "Session A's row.", updatedAt: epoch)
        let rowB = AutoDevEngagement(
            sessionID: sessionB.id, cardID: cards[0].id, attempts: 2,
            disposition: .engaged, reason: "Session B's row.", updatedAt: epoch)
        try await store.saveAutoDevSession(sessionA, cards: [rowA])
        try await store.saveAutoDevSession(sessionB, cards: [rowB])

        let readA = try await store.autoDevEngagements(sessionID: sessionA.id)
        let readB = try await store.autoDevEngagements(sessionID: sessionB.id)
        #expect(readA.count == 1)
        #expect(readB.count == 1)
        #expect(readA.first?.reason == "Session A's row.")
        #expect(readB.first?.reason == "Session B's row.")
        #expect(readA.first?.attempts == 1)
        #expect(readB.first?.attempts == 2)
    }

    // Fix round 1 — the review's Critical finding: dropping either `ON DELETE
    // CASCADE` on `autoDevEngagement` left the full suite green. The next two
    // tests pin both edges of the migration's own claim — "deleting a card
    // takes its row with it, so a card a user deleted mid-session leaves the
    // session rather than holding it open for ever" — and each was confirmed to
    // redden when its own cascade is dropped (see the fix-round report).

    @Test("Deleting a card takes its engagement row with it, and leaves the session alone")
    func deletingACardTakesItsEngagementRow() async throws {
        let (store, repo, cards) = try await seeded()
        let session = AutoDevSession(
            repoID: repo.id, engagedCardIDs: cards.map(\.id), maxAttemptsPerCard: 2,
            patience: 900, startedAt: epoch)
        let rows = cards.map {
            AutoDevEngagement(
                sessionID: session.id, cardID: $0.id, attempts: 0,
                disposition: .engaged, reason: "Not started.", updatedAt: epoch)
        }
        try await store.saveAutoDevSession(session, cards: rows)

        try await store.deleteCard(id: cards[0].id)

        let readRows = try await store.autoDevEngagements(sessionID: session.id)
        #expect(readRows.count == 2)
        #expect(Set(readRows.map(\.cardID)) == Set(cards[1...].map(\.id)))
        // The session itself is untouched — only the one row that named the
        // deleted card is gone.
        #expect(try await store.autoDevSession(id: session.id) != nil)
    }

    /// The card's cascade (`autoDevEngagement.cardID → card`) and the session's
    /// cascade (`autoDevEngagement.sessionID → autoDevSession`) both ultimately
    /// hang off `repo` — `card.repoID` and `autoDevSession.repoID` each cascade
    /// from the same table. Deleting *the session's own repo* would therefore
    /// exercise both edges at once whenever a session and its engaged cards
    /// share a repository, and a broken session cascade would still pass this
    /// test because the card cascade deletes the identical row.
    ///
    /// To isolate the session edge, this test parks the session under a
    /// *second*, otherwise-unrelated repository — nothing in the schema
    /// requires `AutoDevSession.repoID` to match its engaged cards' `repoID`,
    /// since `engagedCardIDs` is a JSON array, not a foreign key. Deleting that
    /// second repo exercises only `repo → autoDevSession → autoDevEngagement`
    /// and never touches the card or its own repo at all.
    @Test("A session's rows go when the session does")
    func deletingASessionTakesItsRowsWithIt() async throws {
        let (store, _, cards) = try await seeded()
        let sessionsRepo = Repo(
            path: "/tmp/repo-\(UUID().uuidString)", nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot (session holder)")
        try await store.saveRepo(sessionsRepo)

        let session = AutoDevSession(
            repoID: sessionsRepo.id, engagedCardIDs: [cards[0].id], maxAttemptsPerCard: 2,
            patience: 900, startedAt: epoch)
        let row = AutoDevEngagement(
            sessionID: session.id, cardID: cards[0].id, attempts: 0,
            disposition: .engaged, reason: "Not started.", updatedAt: epoch)
        try await store.saveAutoDevSession(session, cards: [row])

        try await store.deleteRepo(id: sessionsRepo.id)

        #expect(try await store.autoDevSession(id: session.id) == nil)
        #expect(try await store.autoDevEngagements(sessionID: session.id).isEmpty)
        // The card, in the repo that was never touched, survives.
        #expect(try await store.card(id: cards[0].id) != nil)
    }
}
