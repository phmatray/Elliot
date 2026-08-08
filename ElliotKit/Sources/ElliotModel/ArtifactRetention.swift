import Foundation

/// One file under Elliot's home, as the retention rule needs to see it.
///
/// Deliberately not a `URL`: the rule never opens anything, and a value type
/// carrying only what it decides on is what lets the whole decision be tested
/// without a directory existing. The sweeper fills these in from `FileManager`
/// and is the only place a real path is touched.
public struct ArtifactFile: Codable, Sendable, Hashable {
    public var path: String
    public var bytes: Int
    public var modified: Date

    public init(path: String, bytes: Int, modified: Date) {
        self.path = path
        self.bytes = bytes
        self.modified = modified
    }
}

/// How long Elliot keeps the files it writes, and how many bytes of them.
///
/// `runs/`, `screenshots/` and `analyses/` are all written on purpose and all
/// useful the day they are written; nothing here is a leak. The defect the rule
/// closes is only that "useful the day it is written" and "kept for ever" had
/// never been separated.
///
/// Measured on the author's machine: **730 files and 31 MB** of `runs/` when
/// #167 was filed, and **754 files and 73 MB** three days later when it was
/// implemented — the second figure being the more useful of the two, since the
/// bytes more than doubled while the file count barely moved. Both are
/// date-stamps rather than facts; what they establish is the direction.
///
/// Pure, in `ElliotModel`, for the reason every rule here is: `now` is a
/// parameter rather than a reading, `protected` is given rather than queried,
/// and no path is ever opened. So the whole of what gets deleted is decided by
/// something `swift test` can drive, and the sweeper above it is left with only
/// the two jobs a test cannot do — listing a directory and unlinking a file.
public enum ArtifactRetention {
    /// Nothing this young is ever removed, whatever the budget says.
    ///
    /// A fortnight is the span over which a run log is still the thing you reach
    /// for when a card looks wrong — long enough to cover a holiday weekend and
    /// the week either side of it.
    public static let keepEverythingYoungerThan: TimeInterval = 14 * 24 * 3600

    /// How many bytes of *older* artefacts a directory may keep.
    ///
    /// ⚠️ This budgets the remainder past the horizon, not the directory total:
    /// young files are kept unconditionally and are not counted against it. So
    /// the honest bound on a directory is "a fortnight of writing, plus this" —
    /// which is the price of the guarantee above, and the right way round, since
    /// a ceiling that could evict this morning's log would be a ceiling nobody
    /// dares turn on.
    ///
    /// Chosen against the measurement rather than against taste: `runs/` holds
    /// 73 MB, so the first run of this sweep deletes nothing — verified against a
    /// copy of that directory, 754 files in and 754 out. A retention rule whose
    /// first run removes something nobody expected is a retention rule that gets
    /// reverted.
    public static let byteCeiling = 512 * 1024 * 1024

    /// Which of `files` may be removed.
    ///
    /// In order: drop anything `protected`, drop anything younger than
    /// `horizon`, sort what is left newest-first, and keep taking until one
    /// would carry the running total past `ceiling` — that file and everything
    /// older than it is what comes back.
    ///
    /// The cut is deliberate, and it is what makes the result explainable: the
    /// rule **never keeps an older file while deleting a newer one**. Skipping
    /// the file that overflows and carrying on with smaller, older ones would
    /// pack the budget more tightly and produce a directory where March survived
    /// and July did not, which is indefensible to whoever came looking for July.
    ///
    /// - Parameters:
    ///   - protected: Paths no sweep may touch — a live run's log and stderr.
    ///     Matched exactly, so the caller owns normalising both sides; see
    ///     `ArtifactSweeper`, which resolves symlinks before it builds either.
    ///   - now: The instant to measure age against. A parameter, so a test can
    ///     state an age instead of arranging one.
    public static func prunable(
        _ files: [ArtifactFile],
        protected: Set<String>,
        now: Date,
        ceiling: Int = byteCeiling,
        horizon: TimeInterval = keepEverythingYoungerThan
    ) -> [ArtifactFile] {
        let candidates = files
            .filter { !protected.contains($0.path) }
            // `>=`, because the constant is named for what it keeps: a file
            // *younger than* the horizon survives, and one exactly at it does
            // not. Strict `>` reads the same until `horizon` is 0, where it
            // quietly keeps everything — and a horizon of 0 is precisely how the
            // sweep gets shown to delete at all, so the one case that would
            // matter is the one it got wrong.
            //
            // `now.timeIntervalSince` rather than an absolute difference: a file
            // dated *ahead* of the clock — which a copied or restored directory
            // routinely carries — gives a negative age and lands on the young
            // side. That is the forgiving direction, held on purpose.
            .filter { now.timeIntervalSince($0.modified) >= horizon }
            // Newest first, and path breaks the tie because `sort(by:)` is not
            // stable in Swift — without it the same inventory could delete
            // different files on two runs. Timestamps collide more often than
            // the naming suggests: a directory copied by hand can flatten a
            // whole afternoon onto one.
            .sorted {
                $0.modified == $1.modified ? $0.path < $1.path : $0.modified > $1.modified
            }

        var kept = 0
        for (index, file) in candidates.enumerated() {
            // The overflow guard is not defensive noise: `bytes` comes from the
            // file system, and a sum of enough of them is a `&+` away from
            // trapping in a sweep that must never be able to stop the app.
            let (total, overflowed) = kept.addingReportingOverflow(file.bytes)
            if overflowed || total > ceiling {
                return Array(candidates[index...])
            }
            kept = total
        }
        return []
    }
}
