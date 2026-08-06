import Foundation

/// A real `git`, for the suites that need a real clone rather than a directory
/// that merely contains a `.git`.
///
/// It lives in `TestSupport` rather than beside the first suite that needed it
/// because two test targets need the same pair — `ElliotProcessTests` proves the
/// verbs, `ElliotEngineTests` proves the classifier built on them — and SwiftPM
/// does not let one test target import another. Two copies of a fixture that
/// spawns a real subprocess would drift, and a drifted fixture makes the two
/// suites disagree about what "behind" even means.
///
/// It reaches `/usr/bin/git` through `Process` directly rather than through
/// `ProcessRunner`, so `TestSupport` keeps depending on nothing.

/// A fixture's `git` refused.
public struct GitFixtureFailed: Error, CustomStringConvertible {
    public let command: String
    public let exitCode: Int32
    public let stderr: String
    public var description: String { "git \(command) exited \(exitCode): \(stderr)" }
}

/// Runs one `git` command and throws unless it exited zero.
///
/// The exit arrives through `terminationHandler`, never `waitUntilExit()`: these
/// fixtures are spawned concurrently by the probe's tests, and a run loop waiting
/// on a notification a sibling can consume first is precisely how a test wedges.
public func git(_ arguments: [String], in cwd: String) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
    process.environment = [
        "PATH": "/usr/bin:/bin",
        "HOME": NSHomeDirectory(),
        "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
        "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
        // No global config, no hooks, no prompts: the fixture must behave the
        // same on a machine whose ~/.gitconfig says something interesting.
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
        "GIT_TERMINAL_PROMPT": "0",
    ]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice

    // Diagnostics to a file rather than a pipe: nothing drains a pipe while the
    // child runs here, and a chatty `git clone` that fills one would deadlock.
    let errorPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("git-fixture-\(UUID().uuidString).err").path
    FileManager.default.createFile(atPath: errorPath, contents: nil)
    let errorHandle = FileHandle(forWritingAtPath: errorPath)
    process.standardError = errorHandle ?? FileHandle.nullDevice
    defer {
        try? errorHandle?.close()
        try? FileManager.default.removeItem(atPath: errorPath)
    }

    let status: Int32 = try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            continuation.resume(throwing: error)
        }
    }
    guard status == 0 else {
        let stderr = (try? String(contentsOfFile: errorPath, encoding: .utf8)) ?? ""
        throw GitFixtureFailed(
            command: arguments.joined(separator: " "), exitCode: status,
            stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// An origin holding one commit, and a clone of it. Both under the temporary
/// directory — no test may write anywhere near a real portfolio.
///
/// Returns `root` as well as the pair, because removing `root` is how a test
/// cleans up both in one line.
public func makeClonePair() async throws -> (origin: String, clone: String, root: String) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("pair-\(UUID().uuidString)").path
    let origin = root + "/origin", clone = root + "/clone"
    try FileManager.default.createDirectory(atPath: origin, withIntermediateDirectories: true)
    try await git(["init", "--initial-branch=main"], in: origin)
    try await git(["commit", "--allow-empty", "-m", "a"], in: origin)
    try await git(["clone", origin, clone], in: root)
    return (origin, clone, root)
}
