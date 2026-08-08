import Foundation
import Testing

@testable import ElliotModel

@Suite("Artefact retention")
struct ArtifactRetentionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func file(_ name: String, bytes: Int, daysOld: Double) -> ArtifactFile {
        ArtifactFile(
            path: "/home/runs/\(name)",
            bytes: bytes,
            modified: now.addingTimeInterval(-daysOld * 24 * 3600)
        )
    }

    @Test("An empty inventory prunes nothing rather than crashing")
    func emptyInventory() {
        #expect(ArtifactRetention.prunable([], protected: [], now: now).isEmpty)
    }

    @Test("A file younger than the horizon survives however far over the ceiling it puts us")
    func youngFilesAreNeverPrunable() {
        // The property that makes this safe to run unattended, and the one worth
        // stating first: a sweep can never take today's work. A ceiling of zero
        // is the strongest form of the question — there is no budget at all, and
        // the young file still has to survive it.
        let young = [
            file("a.ndjson", bytes: 900_000_000, daysOld: 0),
            file("b.ndjson", bytes: 900_000_000, daysOld: 13.9),
        ]
        #expect(ArtifactRetention.prunable(young, protected: [], now: now, ceiling: 0).isEmpty)
    }

    @Test("A file the board still points at survives at any age and any size")
    func protectedFilesAreNeverPrunable() {
        // Age and size are the two axes the rule otherwise decides on, so the
        // protection is checked with both pushed as far as they go: ancient and
        // enormous, with no budget to keep it in.
        let files = [
            file("live.ndjson", bytes: 900_000_000, daysOld: 4000),
            file("dead.ndjson", bytes: 1, daysOld: 4000),
        ]
        let pruned = ArtifactRetention.prunable(
            files, protected: ["/home/runs/live.ndjson"], now: now, ceiling: 0
        )
        #expect(pruned.map(\.path) == ["/home/runs/dead.ndjson"])
    }

    @Test("Past the horizon, the newest are kept until the ceiling and the rest returned")
    func oldFilesAreKeptNewestFirstUntilTheCeiling() {
        // Four 100-byte files, all old, against a 250-byte ceiling: two fit, the
        // third would take the total to 300, so it and everything older go.
        let files = [
            file("d.ndjson", bytes: 100, daysOld: 40),
            file("b.ndjson", bytes: 100, daysOld: 20),
            file("c.ndjson", bytes: 100, daysOld: 30),
            file("a.ndjson", bytes: 100, daysOld: 15),
        ]
        let pruned = ArtifactRetention.prunable(files, protected: [], now: now, ceiling: 250)
        #expect(pruned.map(\.path) == ["/home/runs/c.ndjson", "/home/runs/d.ndjson"])
    }

    @Test("The kept set never contains a file older than a pruned one")
    func retentionIsMonotoneInAge() {
        // The invariant behind the cut-off, stated as an invariant rather than as
        // one example. The alternative reading of "keep until the ceiling" — skip
        // the file that would overflow and carry on trying smaller, older ones —
        // is a knapsack, and it produces sets where a file from March survives
        // while one from July is deleted. That is indefensible to whoever comes
        // looking for the newer one, so the rule cuts and stops.
        let files = (0..<20).map { i in
            file("f\(i).ndjson", bytes: i == 3 ? 10_000 : 10, daysOld: Double(20 + i))
        }
        let pruned = ArtifactRetention.prunable(files, protected: [], now: now, ceiling: 100)
        let prunedPaths = Set(pruned.map(\.path))
        let kept = files.filter { !prunedPaths.contains($0.path) }

        let newestPruned = pruned.map(\.modified).max()
        let oldestKept = kept.map(\.modified).min()
        if let newestPruned, let oldestKept {
            #expect(oldestKept > newestPruned)
        }
        // The big file at index 3 is the one that breaks the budget, so it and
        // the 16 behind it go, and only the three ahead of it are kept.
        #expect(kept.map(\.path) == ["/home/runs/f0.ndjson", "/home/runs/f1.ndjson", "/home/runs/f2.ndjson"])
    }

    @Test("Everything old fits under the ceiling, so nothing is pruned")
    func nothingIsPrunedWhenTheOldFilesFit() {
        // Today's expected answer, and the one the defaults were chosen to give:
        // a directory well inside its budget loses nothing. A retention rule
        // whose first run deletes something is a retention rule that gets reverted.
        let files = (0..<50).map { file("f\($0).ndjson", bytes: 1000, daysOld: 100) }
        #expect(ArtifactRetention.prunable(files, protected: [], now: now, ceiling: 512 * 1024).isEmpty)
    }

    @Test("Files sharing a modification date are ordered by path, so the answer is stable")
    func tiesAreBrokenDeterministically() {
        // `sort(by:)` is not stable in Swift, so equal timestamps alone would let
        // two runs of the same inventory delete different files. Screenshots are
        // named to the millisecond and runs to the UUID, but a copied directory
        // — which is exactly how this gets verified by hand — can flatten a whole
        // afternoon onto one timestamp.
        let files = ["c", "a", "d", "b"].map { file("\($0).ndjson", bytes: 100, daysOld: 30) }
        let first = ArtifactRetention.prunable(files, protected: [], now: now, ceiling: 250)
        let second = ArtifactRetention.prunable(files.reversed(), protected: [], now: now, ceiling: 250)
        #expect(first.map(\.path) == second.map(\.path))
        #expect(first.map(\.path) == ["/home/runs/c.ndjson", "/home/runs/d.ndjson"])
    }

    @Test("The horizon is a parameter, so a sweep can be asked to prune everything old")
    func horizonIsOverridable() {
        // Task 5 of the plan turns the horizon off to prove the sweep genuinely
        // deletes when the rule says so — a no-op that is a no-op for the wrong
        // reason is not evidence. That check needs the horizon to be a parameter
        // rather than only a constant.
        let files = [file("fresh.ndjson", bytes: 100, daysOld: 0)]
        #expect(ArtifactRetention.prunable(files, protected: [], now: now, ceiling: 0).isEmpty)
        #expect(
            ArtifactRetention.prunable(files, protected: [], now: now, ceiling: 0, horizon: 0)
                .map(\.path) == ["/home/runs/fresh.ndjson"]
        )
    }

    @Test("The defaults leave today's directory alone")
    func defaultsAreANoOpOnTodaysData() {
        // The measurement from the issue: 730 files, 31 MB, all written in the
        // last fortnight. Pinned here so a later change to either constant has to
        // face what it does to the directory that motivated the feature.
        #expect(ArtifactRetention.keepEverythingYoungerThan == 14 * 24 * 3600)
        #expect(ArtifactRetention.byteCeiling == 512 * 1024 * 1024)

        let todaysRuns = (0..<730).map { file("f\($0).ndjson", bytes: 42_000, daysOld: Double($0 % 14)) }
        #expect(ArtifactRetention.prunable(todaysRuns, protected: [], now: now).isEmpty)
    }

    @Test("A file dated in the future is young, not ancient")
    func clockSkewCountsAsYoung() {
        // A copied or restored directory can carry a modification date ahead of
        // the clock. `now.timeIntervalSince(modified)` goes negative there, and a
        // comparison written as `age > horizon` reads that as young — which is
        // the forgiving direction, and the one to hold on purpose rather than by
        // accident.
        let files = [file("ahead.ndjson", bytes: 900_000_000, daysOld: -3)]
        #expect(ArtifactRetention.prunable(files, protected: [], now: now, ceiling: 0).isEmpty)
    }
}
