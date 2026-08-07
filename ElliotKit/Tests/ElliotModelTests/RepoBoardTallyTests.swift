import Foundation
import Testing

@testable import ElliotModel

/// A row the way the reconciler builds one, with only the two fields the
/// entitlement rule reads varied. Everything else is scenery: the rule is
/// `repoID` and `issue`, and a helper that let a test vary anything else would
/// invite the reader to think otherwise.
private func row(
    _ issue: RepoIssue, repoID: UUID? = nil, id: String = "phmatray/Koine"
) -> RepoRow {
    RepoRow(
        id: id, nameWithOwner: id, path: "/R/\(id)", repoID: repoID, issue: issue,
        detail: "unchanged", fixes: [.forget(repoID: repoID ?? UUID())])
}

private func tally(cards: Int, running: Int = 0) -> RepoBoardTally {
    RepoBoardTally(cards: cards, runsInFlight: running, spendToday: .nothing)
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

@Suite("Repo board digest")
struct RepoBoardDigestTests {

    @Test("A driven row gets the figures the store measured for it")
    func entitledRowKeepsItsFigures() {
        let id = UUID()
        let decorated = RepoBoardDigest.decorate(
            [row(.ok, repoID: id)], tallies: [id: tally(cards: 11, running: 2)], failures: [:])
        #expect(decorated[0].board?.cards == 11)
        #expect(decorated[0].board?.runsInFlight == 2)
        #expect(decorated[0].board?.refreshFailure == nil)
    }

    /// Criterion 3. The store's `GROUP BY` returns no row at all for a
    /// repository with no cards, so absence is the seam where "none" would
    /// become "not ours" if this defaulted to `nil`.
    @Test("A driven row the store never mentioned says none, not nothing")
    func absentEntitledRowIsEmptyNotNil() {
        let decorated = RepoBoardDigest.decorate(
            [row(.ok, repoID: UUID())], tallies: [:], failures: [:])
        #expect(decorated[0].board == .empty)
        #expect(decorated[0].board != nil)
    }

    /// Criterion 4, and the case that defeats a view-level `if let tally`.
    /// The fork holds a `repoID` *and* an entry in both dictionaries, and still
    /// comes back with nothing: the entitlement is the row's, not the
    /// dictionary's.
    @Test("An out-of-scope row is given nothing, whatever the dictionaries hold")
    func outOfScopeRowIsDroppedEvenWhenMeasured() {
        let id = UUID()
        let decorated = RepoBoardDigest.decorate(
            [row(.outOfScope(.fork), repoID: id)],
            tallies: [id: tally(cards: 9)], failures: [id: "gh exited 1"])
        #expect(decorated[0].board == nil)
    }

    /// Criterion 2 at this layer: the failure is session state and arrives on a
    /// different clock from the figures, so it must not need the store to have
    /// seen the repository at all.
    @Test("A failure reaches a row the store has never seen")
    func failureWithoutTally() {
        let id = UUID()
        let decorated = RepoBoardDigest.decorate(
            [row(.ok, repoID: id)], tallies: [:], failures: [id: "gh exited 1: no network"])
        #expect(decorated[0].board?.cards == 0)
        #expect(decorated[0].board?.refreshFailure == "gh exited 1: no network")
    }

    @Test("A failure that has cleared leaves no mark on a row that still has figures")
    func clearedFailure() {
        let id = UUID()
        let decorated = RepoBoardDigest.decorate(
            [row(.ok, repoID: id, id: "phmatray/Koine")],
            tallies: [id: RepoBoardTally(
                cards: 3, runsInFlight: 0, spendToday: .nothing, refreshFailure: "stale")],
            failures: [:])
        #expect(decorated[0].board?.refreshFailure == nil)
        #expect(decorated[0].board?.cards == 3)
    }

    @Test("Nothing else about a row moves: same rows, same order, same fields")
    func everythingElseIsUntouched() {
        let driven = UUID()
        let rows = [
            row(.ok, repoID: driven, id: "phmatray/Koine"),
            row(.outOfScope(.archived), repoID: UUID(), id: "phmatray/Yendor"),
            row(.notRegistered, id: "phmatray/Ducky"),
        ]
        let decorated = RepoBoardDigest.decorate(
            rows, tallies: [driven: tally(cards: 4)], failures: [:])
        #expect(decorated.count == rows.count)
        #expect(decorated.map(\.id) == rows.map(\.id))
        #expect(decorated.map(\.issue) == rows.map(\.issue))
        #expect(decorated.map(\.detail) == rows.map(\.detail))
        #expect(decorated.map(\.path) == rows.map(\.path))
        #expect(decorated.map(\.fixes) == rows.map(\.fixes))
        #expect(decorated.map(\.repoID) == rows.map(\.repoID))
    }
}
