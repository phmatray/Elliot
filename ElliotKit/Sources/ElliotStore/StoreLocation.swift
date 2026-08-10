import ElliotModel
import Foundation

/// Where Elliot keeps its state on disk.
///
/// The app and the MCP helper are separate processes that must agree on these
/// paths without talking to each other first, so they are computed, never
/// passed around. `ELLIOT_HOME` overrides everything, which is what the tests
/// and the fake-tool harness use.
public enum StoreLocation {
    public static var home: URL {
        if let override = ProcessInfo.processInfo.environment["ELLIOT_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Elliot", isDirectory: true)
    }

    public static var databaseURL: URL {
        home.appendingPathComponent("elliot.sqlite")
    }

    /// What the reader chose about how the app looks, beside the board's own
    /// state rather than in `UserDefaults`.
    ///
    /// `UserDefaults.standard` is keyed by bundle identifier, so nothing can
    /// point it at a different home — and every on-screen verification in this
    /// project runs against a scratch `ELLIOT_HOME`, where a preference bleeding
    /// in from the operator's real app means the capture does not show what it
    /// claims. Derived from ``home``, this follows the variable by construction,
    /// which is the difference between an isolation nobody can forget and one
    /// everybody has to remember.
    ///
    /// Not board state, so it never crosses the MCP socket and the sole-writer
    /// rule does not reach it.
    public static var preferencesURL: URL {
        home.appendingPathComponent("preferences.json")
    }

    /// One NDJSON file per run, holding every line the CLI emitted. This is the
    /// durable sink: the UI stream is bounded and may drop, this never does.
    public static var runsDirectory: URL {
        home.appendingPathComponent("runs", isDirectory: true)
    }

    public static func runLogURL(runID: UUID) -> URL {
        runsDirectory.appendingPathComponent("\(runID.uuidString).ndjson")
    }

    public static func runStderrURL(runID: UUID) -> URL {
        runsDirectory.appendingPathComponent("\(runID.uuidString).stderr.log")
    }

    /// One directory per analysis run, holding the `stories.json` the run was
    /// told to write. Kept beside the run's log so a harvest can be repeated
    /// from disk without spawning anything.
    public static var analysesDirectory: URL {
        home.appendingPathComponent("analyses", isDirectory: true)
    }

    public static func analysisRunDirectory(analysisID: UUID, runID: UUID) -> URL {
        analysesDirectory
            .appendingPathComponent(analysisID.uuidString, isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
    }

    public static func analysisArtifactURL(analysisID: UUID, runID: UUID) -> URL {
        analysisRunDirectory(analysisID: analysisID, runID: runID)
            .appendingPathComponent("stories.json")
    }

    /// One directory per appraisal run, holding the `appraisal.json` the run was
    /// told to write.
    ///
    /// Keyed on the run alone, where an analysis is keyed on `(analysisID,
    /// runID)`: an appraisal belongs to a **card**, not to an analysis, which is
    /// what lets it satisfy `skillRun`'s XOR check without a migration. There is
    /// therefore no analysis id to nest under — and the card's id is deliberately
    /// not used either, since an artifact keyed on the card would be overwritten
    /// by the next appraisal of that card, leaving an older run's report pointing
    /// at somebody else's file.
    ///
    /// Under `analysesDirectory` all the same, so `ensureDirectories` already
    /// creates the parent 0o700 and one owner-only tree holds everything a
    /// read-only run writes.
    public static func appraisalRunDirectory(runID: UUID) -> URL {
        analysesDirectory
            .appendingPathComponent("appraisals", isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
    }

    public static func appraisalArtifactURL(runID: UUID) -> URL {
        appraisalRunDirectory(runID: runID).appendingPathComponent("appraisal.json")
    }

    /// One PNG per `board_screenshot` call, at full resolution.
    ///
    /// The same bargain the runs directory strikes: what travels back to an
    /// agent is bounded and may be resampled, and this is the copy that is not.
    /// A picture small enough to read in a reply is often too small to read a
    /// column caption in.
    public static var screenshotsDirectory: URL {
        home.appendingPathComponent("screenshots", isDirectory: true)
    }

    /// Named by window and instant rather than by a UUID, because these are read
    /// by a human looking for "the board, just now" far more often than they are
    /// looked up by key.
    public static func screenshotURL(window: String, at moment: Date) -> URL {
        // Built per call rather than cached in a static: `ISO8601DateFormatter`
        // is a class with mutable state and is not `Sendable`, so a shared one is
        // a data race the compiler correctly refuses. A screenshot costs a
        // window render and a file write; a formatter allocation is not the part
        // worth optimising.
        let formatter = ISO8601DateFormatter()
        // Fractional seconds, because whole ones collide. Two captures of the
        // same window inside one second resolved to one path, and the second
        // `write(options: .atomic)` replaced the first — leaving the first
        // call's already-returned `pngPath` pointing at different pixels. A
        // before/after pair taken in quick succession is exactly how this tool
        // gets used.
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Colons are legal on APFS but make the path miserable to quote in a
        // shell, which is exactly what someone does with a screenshot path.
        let stamp = formatter.string(from: moment).replacingOccurrences(of: ":", with: "-")
        return screenshotsDirectory.appendingPathComponent("\(window)-\(stamp).png")
    }

    public static var socketURL: URL { home.appendingPathComponent("ipc.sock") }
    public static var tokenURL: URL { home.appendingPathComponent("ipc.token") }

    /// The one spelling of a path that the retention sweep compares on.
    ///
    /// ⛔ **Both sides of the protection test must come through here.** The
    /// safety rule — never delete a file a live run points at — is a set
    /// membership test between `SkillRun.logPath` and what `inventory(of:)`
    /// found, and both are strings. `FileManager`'s enumerator hands back
    /// **symlink-resolved** URLs, while a `logPath` recorded from
    /// `runLogURL(runID:)` is whatever `ELLIOT_HOME` said; on macOS `/tmp` is a
    /// symlink to `/private/tmp`, and `/tmp/elliot-check` is the scratch home
    /// this project's own verification recipe uses. So the two spellings differ
    /// in exactly the setup a check runs under, the membership test quietly
    /// stops matching, and the sweep deletes a live run's log — failing **open**,
    /// with nothing on screen to say so.
    ///
    /// Applied explicitly rather than left to the enumerator, which resolves as
    /// an undocumented convenience: a normalisation that happens by accident on
    /// one side of a comparison is one release away from not happening.
    public static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Every file under `directory`, with the two facts the retention rule
    /// decides on.
    ///
    /// The impure half of the sweep, and deliberately the whole of it: what to
    /// delete is `ArtifactRetention`'s to say, and it can say it without a
    /// directory existing. This only reads.
    ///
    /// - Returns: One entry per *regular file*, at any depth. Empty for a
    ///   directory that does not exist — `ensureDirectories()` creates all three
    ///   at launch, so that is the state of a fresh home for the instant before
    ///   it, and a sweep that threw there is a sweep that could stop the app
    ///   from starting.
    ///
    /// Depth matters: `analyses/` nests two levels (`<analysisID>/<runID>/`), so
    /// a flat listing would report directories where the files are. Directories
    /// are descended into and never returned as entries — the caller unlinks
    /// what comes back, and unlinking a directory is a different act.
    ///
    /// An entry whose size or date cannot be read — a dangling symlink is the
    /// ordinary case — is **dropped**. Substituting a default would put an age
    /// nobody measured into a decision about deleting things.
    public static func inventory(of directory: URL) throws -> [ArtifactFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        // `errorHandler` returning true keeps the walk going past a directory it
        // cannot open, which is the same bargain as dropping an unreadable file:
        // one unreachable corner must not cost the sweep the rest of the tree.
        guard let walk = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var found: [ArtifactFile] = []
        for case let url as URL in walk {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let bytes = values.fileSize,
                  let modified = values.contentModificationDate
            else { continue }
            found.append(
                ArtifactFile(path: canonicalPath(url.path), bytes: bytes, modified: modified)
            )
        }
        return found
    }

    /// Creates the directory tree with owner-only permissions. The socket and
    /// token live here, so the parent must not be group- or world-readable.
    public static func ensureDirectories() throws {
        for url in [home, runsDirectory, analysesDirectory, screenshotsDirectory] {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }
}
