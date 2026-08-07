import Foundation
import Testing

@testable import ElliotModel

/// A row the way the reconciler builds one, with only the two fields the
/// entitlement rule reads varied. Everything else is scenery: the rule is
/// `repoID` and `issue`, and a helper that let a test vary anything else would
/// invite the reader to think otherwise.
private func row(_ issue: RepoIssue, repoID: UUID? = nil) -> RepoRow {
    RepoRow(
        id: "phmatray/Koine", nameWithOwner: "phmatray/Koine",
        path: "/R/phmatray/private/Koine", repoID: repoID, issue: issue)
}

@Suite("Repo board tally")
struct RepoBoardTallyTests {

    @Test("A row Elliot does not drive carries no figures, however it got there")
    func notEntitled() {
        // No registration at all: there is no board to have figures on.
        #expect(row(.notRegistered).showsBoardFigures == false)
        // The case that defeats `repoID != nil` on its own. A registered fork
        // *has* an id — `RepoReconciler.row(for:)` sets `repoID: repo?.id` on
        // the out-of-scope branch — and it is still not ours to drive.
        #expect(row(.outOfScope(.fork), repoID: UUID()).showsBoardFigures == false)
        #expect(row(.outOfScope(.archived), repoID: UUID()).showsBoardFigures == false)
        #expect(row(.outOfScope(.otherRoot), repoID: UUID()).showsBoardFigures == false)
    }

    @Test("A registered row carries figures whatever its verdict says about the disk")
    func entitled() {
        // `.missing`, `.unlisted` and `.notChecked` especially: the store
        // answered even though the disk or GitHub did not, and saying so is the
        // point of the row.
        for issue: RepoIssue in [.ok, .missing, .unlisted, .notChecked, .behind(by: 3)] {
            #expect(row(issue, repoID: UUID()).showsBoardFigures == true, "\(issue)")
        }
    }

    @Test("A row built the way the reconciler builds one carries no tally")
    func defaultsToNil() {
        #expect(row(.ok, repoID: UUID()).board == nil)
    }

    @Test("An empty tally is zero of everything, and knows nothing failed")
    func emptyTally() {
        #expect(RepoBoardTally.empty.cards == 0)
        #expect(RepoBoardTally.empty.runsInFlight == 0)
        #expect(RepoBoardTally.empty.spendToday == .nothing)
        #expect(RepoBoardTally.empty.refreshFailure == nil)
    }
}
