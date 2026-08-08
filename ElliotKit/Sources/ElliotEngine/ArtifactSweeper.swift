import ElliotModel
import ElliotStore
import Foundation
import os

/// What one pass of the sweep removed.
///
/// Two numbers rather than one because they answer different questions — "did
/// anything happen" and "was it worth doing" — and because a count alone would
/// report a directory that shed 700 empty files and one that shed 700 MB
/// identically.
public struct SweepReport: Sendable, Equatable {
    public var removed = 0
    public var bytes = 0

    public init(removed: Int = 0, bytes: Int = 0) {
        self.removed = removed
        self.bytes = bytes
    }

    /// Whether this is worth telling the reader about at all. An empty sweep is
    /// the expected result and must not read as a finding.
    public var isEmpty: Bool { removed == 0 }
}

/// Applies ``ArtifactRetention`` to the directories Elliot writes into.
///
/// The impure half of the feature, and deliberately a thin one: it lists, it
/// asks, it unlinks. *What* goes is `ArtifactRetention`'s, which is pure and
/// tested without a directory existing, and the paths come from
/// `StoreLocation.inventory(of:)`. Nothing here decides retention.
///
/// An `actor`, so a sweep is off the main actor by construction rather than by
/// the caller remembering to put it there — it runs while the board is being
/// dragged, and neither a run nor a screenshot capture waits on it.
///
/// ⛔ **Nothing in here throws.** It is called once at launch, next to the
/// reconciler's sweep, and housekeeping that can stop the app from starting is
/// worse than housekeeping that never runs. A directory it cannot read
/// contributes nothing; a file it cannot unlink is logged and skipped, and — the
/// part that is easy to get wrong — is *not counted*, because a report that
/// counted intentions would claim a directory had shrunk when it had not.
public actor ArtifactSweeper {
    /// The three directories that grow without bound: one NDJSON log and one
    /// stderr file per run, one PNG per `board_screenshot`, one `stories.json`
    /// per analysis run.
    public static var defaultDirectories: [URL] {
        [
            StoreLocation.runsDirectory,
            StoreLocation.screenshotsDirectory,
            StoreLocation.analysesDirectory,
        ]
    }

    private let store: BoardStore
    private let directories: [URL]
    private let ceiling: Int
    private let horizon: TimeInterval
    private let log = Logger(subsystem: "dev.phmatray.elliot", category: "artifact-sweep")

    public init(
        store: BoardStore,
        directories: [URL] = ArtifactSweeper.defaultDirectories,
        ceiling: Int = ArtifactRetention.byteCeiling,
        horizon: TimeInterval = ArtifactRetention.keepEverythingYoungerThan
    ) {
        self.store = store
        self.directories = directories
        self.ceiling = ceiling
        self.horizon = horizon
    }

    /// Removes what the rule says may go, and reports what actually went.
    ///
    /// - Parameter now: The instant age is measured against. A parameter for the
    ///   same reason `ArtifactRetention.prunable` takes one — so the decision is
    ///   reproducible — and defaulted so the launch path reads plainly.
    @discardableResult
    public func sweep(now: Date = Date()) async -> SweepReport {
        // ⛔ No protected set, no sweep. The obvious shape here — `?? []` — is
        // the fail-*open* one: it turns "I could not find out which runs are
        // live" into "no run is live", and deletes the log of every run in
        // flight. A failure to read the board is a reason not to touch the disk,
        // not a licence to.
        guard let protected = await protectedPaths() else {
            log.error("skipping the artefact sweep: the runs table could not be read")
            return SweepReport()
        }
        var report = SweepReport()

        for directory in directories {
            // Read once per directory rather than once for all three: they are
            // budgeted separately, which is what "512 MB per directory" means.
            let files = (try? StoreLocation.inventory(of: directory)) ?? []
            for file in ArtifactRetention.prunable(
                files, protected: protected, now: now, ceiling: ceiling, horizon: horizon
            ) {
                do {
                    try FileManager.default.removeItem(atPath: file.path)
                    report.removed += 1
                    report.bytes += file.bytes
                } catch {
                    // Skipped, not retried and not thrown. The file will be
                    // offered again by the next launch's sweep, which is the
                    // right amount of insistence for housekeeping.
                    log.error("could not remove \(file.path, privacy: .public): \(error)")
                }
            }
        }
        return report
    }

    /// The paths no sweep may touch: the log and stderr of every run that is
    /// still in flight.
    ///
    /// Non-terminal only, and that is the whole bound the feature provides —
    /// every one of the 730 files measured belongs to a run that ended, so
    /// protecting finished runs too would protect everything.
    ///
    /// The other half of the guarantee is not here: "never a file written in the
    /// current session" is the *horizon*'s, since anything written this session
    /// is younger than a fortnight. Two mechanisms, on purpose — this one covers
    /// a live run whose log happens to be ancient, which a horizon cannot.
    ///
    /// ⛔ Both sides go through `StoreLocation.canonicalPath`. A `logPath` is
    /// recorded from `runLogURL` and the inventory comes from `FileManager`,
    /// which resolves symlinks; on a home reached through one — `/tmp` is a
    /// symlink on macOS, and `/tmp/elliot-check` is this project's own scratch
    /// home — the two spellings differ, the membership test stops matching, and
    /// the sweep deletes a live run's log. It fails **open**, and silently, which
    /// is why the normalisation is a named function used by both sides rather
    /// than a habit.
    /// - Returns: `nil` when the board could not be read at all, which the caller
    ///   treats as a reason to skip the sweep. Distinct from an empty set, which
    ///   is the ordinary answer on a board with nothing in flight and does permit
    ///   a sweep.
    private func protectedPaths() async -> Set<String>? {
        guard let runs = try? await store.nonTerminalRuns() else { return nil }
        return Set(
            runs.flatMap { [$0.logPath, $0.stderrPath] }.map(StoreLocation.canonicalPath)
        )
    }
}
