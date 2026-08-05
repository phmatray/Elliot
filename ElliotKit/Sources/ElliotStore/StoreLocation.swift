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

    public static var socketURL: URL { home.appendingPathComponent("ipc.sock") }
    public static var tokenURL: URL { home.appendingPathComponent("ipc.token") }

    /// Creates the directory tree with owner-only permissions. The socket and
    /// token live here, so the parent must not be group- or world-readable.
    public static func ensureDirectories() throws {
        for url in [home, runsDirectory, analysesDirectory] {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }
}
