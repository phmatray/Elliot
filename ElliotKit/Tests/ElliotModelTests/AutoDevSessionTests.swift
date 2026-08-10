import Foundation
import Testing

@testable import ElliotModel

/// The vocabulary the screen renders and the loop will persist.
///
/// Pure — no store, no clock, no `Date()` anywhere but a fixed fixture. The
/// tally is the piece with teeth: the band's headline and the status bar's
/// figure both read it, and two hand-rolled counts would be two answers to the
/// one number this feature exists to state.
@Suite("Auto-dev session")
struct AutoDevSessionTests {

    /// Fixed rather than `Date()`, for the reason `AppModelTests` gives:
    /// `ElliotModel` holds no clock, and a fixture reaching for the wall clock
    /// makes a test depend on when the suite happened to run.
    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    private func engagement(
        _ disposition: AutoDevDisposition, session: UUID, attempts: Int = 1
    ) -> AutoDevEngagement {
        AutoDevEngagement(
            sessionID: session, cardID: UUID(), attempts: attempts,
            disposition: disposition, reason: "Because.", updatedAt: epoch
        )
    }

    @Test("The tally counts each disposition, and settled is merged plus blocked")
    func tallyCounts() {
        let session = UUID()
        let tally = AutoDevTally.of([
            engagement(.engaged, session: session),
            engagement(.engaged, session: session),
            engagement(.merged, session: session),
            engagement(.blocked, session: session),
            engagement(.blocked, session: session),
        ])

        #expect(tally.engaged == 2)
        #expect(tally.merged == 1)
        #expect(tally.blocked == 2)
        #expect(tally.total == 5)
        // The figure reads this. A card still engaged is not settled, and a
        // blocked one is — the session is done with it either way.
        #expect(tally.settled == 3)
    }

    @Test("No rows is zero of zero, not a crash and not a one")
    func emptyTally() {
        let tally = AutoDevTally.of([])
        #expect(tally == AutoDevTally(engaged: 0, merged: 0, blocked: 0))
        #expect(tally.total == 0)
        #expect(tally.settled == 0)
    }

    /// Three dispositions and not five. The loop's own verdict — retry, wait,
    /// held, settle, abort — is a decision about the *next round*; this is what
    /// the report says about the card, and the distinctions the decision draws
    /// are carried by `reason`.
    @Test("Every disposition has a distinct raw value")
    func dispositionsAreDistinct() {
        let raws = AutoDevDisposition.allCases.map(\.rawValue)
        #expect(Set(raws).count == AutoDevDisposition.allCases.count)
        #expect(raws.allSatisfy { !$0.isEmpty })
    }

    /// The engaged list is closed at start, so `id` may be the card: a session
    /// cannot hold two rows for one card. `ForEach` in the band depends on it.
    @Test("An engagement identifies itself by its card")
    func engagementIsIdentifiedByItsCard() {
        let row = engagement(.merged, session: UUID())
        #expect(row.id == row.cardID)
    }

    /// PR4 persists this. A shape that does not survive a round trip is a
    /// report that comes back from the store as something else.
    @Test("A session round-trips through Codable with its engaged list in order")
    func sessionRoundTrips() throws {
        let cards = [UUID(), UUID(), UUID()]
        let session = AutoDevSession(
            repoID: UUID(), engagedCardIDs: cards, maxAttemptsPerCard: 3,
            patience: 900, startedAt: epoch, state: .paused
        )

        let data = try JSONEncoder().encode(session)
        let back = try JSONDecoder().decode(AutoDevSession.self, from: data)

        #expect(back == session)
        // Order, not membership: the report renders these rows in the order the
        // session engaged them.
        #expect(back.engagedCardIDs == cards)
        #expect(back.state == .paused)
        #expect(back.endedAt == nil)
    }

    @Test("Every state is nameable, and no two share a raw value")
    func statesAreDistinct() {
        let raws = AutoDevSession.State.allCases.map(\.rawValue)
        #expect(Set(raws).count == 3)
    }
}
