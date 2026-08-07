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
        formatter.formatOptions = [.withInternetDateTime]
        // Colons are legal on APFS but make the path miserable to quote in a
        // shell, which is exactly what someone does with a screenshot path.
        let stamp = formatter.string(from: moment).replacingOccurrences(of: ":", with: "-")
        return screenshotsDirectory.appendingPathComponent("\(window)-\(stamp).png")
    }

    public static var socketURL: URL { home.appendingPathComponent("ipc.sock") }
    public static var tokenURL: URL { home.appendingPathComponent("ipc.token") }

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
