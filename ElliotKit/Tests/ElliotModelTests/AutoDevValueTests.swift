import Foundation
import Testing

@testable import ElliotModel

/// The transient verdict a policy round produces, and the total mapping onto the row a session's
/// report persists.
///
/// `AutoDevSession`'s own shape is pinned by `AutoDevSessionTests` (PR5's) and is not repeated
/// here — this task declares nothing about it. What this task adds is `Disposition` and
/// `engagement`, so that is what this suite pins.
@Suite("Auto-dev values")
struct AutoDevValueTests {

    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    @Test("A disposition's sentence is written once, on the disposition")
    func dispositionRenders() {
        #expect(Disposition.retry.reason == "Moving this card now.")
        #expect(Disposition.wait(reason: "Waiting on CI.").reason == "Waiting on CI.")
        #expect(Disposition.held(.paused).reason == QueueRefusal.paused.sentence)
        #expect(Disposition.settle(.merged, reason: "Merged.").reason == "Merged.")
        #expect(Disposition.abortSession(reason: "Blocked.").reason == "Blocked.")
    }

    @Test("Only settling and aborting settle a card")
    func settledIsTwoCases() {
        #expect(Disposition.settle(.merged, reason: "x").isSettled)
        #expect(Disposition.settle(.blocked, reason: "x").isSettled)
        #expect(Disposition.abortSession(reason: "x").isSettled)
        #expect(Disposition.retry.isSettled == false)
        #expect(Disposition.wait(reason: "x").isSettled == false)
        #expect(Disposition.held(.paused).isSettled == false)
    }

    @Test("A row agrees with its disposition about being settled")
    func rowAgrees() {
        var row = AutoDevEngagement(
            sessionID: UUID(), cardID: UUID(), attempts: 1,
            disposition: .merged, reason: "Merged.", updatedAt: epoch
        )
        #expect(row.isSettled)
        row.disposition = .blocked
        #expect(row.isSettled)
        row.disposition = .engaged
        #expect(row.isSettled == false)
    }

    /// The whole product of this task: every later task writes a row through `engagement`, so a
    /// gap in this switch is a card silently reported as still engaged.
    @Test("A disposition's engagement is total, and settle's outcome passes straight through")
    func engagementIsTotal() {
        #expect(Disposition.retry.engagement == .engaged)
        #expect(Disposition.wait(reason: "x").engagement == .engaged)
        #expect(Disposition.held(.paused).engagement == .engaged)
        #expect(Disposition.settle(.merged, reason: "x").engagement == .merged)
        #expect(Disposition.settle(.blocked, reason: "x").engagement == .blocked)
        #expect(Disposition.abortSession(reason: "x").engagement == .blocked)
    }
}
