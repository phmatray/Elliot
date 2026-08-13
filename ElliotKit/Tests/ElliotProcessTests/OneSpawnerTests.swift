import Foundation
import Testing

/// `ChildProcess` is the only thing in this package that starts a child, drains its pipes and
/// publishes its exit. That was true until a vendored ACP library arrived carrying five more
/// spawners — three of which called `waitUntilExit()`, which this repository's production rule
/// forbids outright.
///
/// #146 is why this is a test and not a comment: the mechanism was written twice before, eight
/// comment lines were byte-identical across the two copies, and three defects were each fixed in
/// one file only. A vendor boundary is a worse place for that to happen, not a better one.
///
/// ## What this test does not see
///
/// A source-text gate, not a proof — modelled on `DrainDuplicationTests`, whose `isCode()` is
/// copied here verbatim so a comment describing this very rule cannot trip or satisfy it. Read a
/// green run as "nothing matched this pattern," never as "no second spawner exists":
///
/// 1. **`isCode()` strips whole-line comments only.** An inline trailing comment on a real code
///    line (`let x = 1  // Process()`), or the token sitting inside a string literal, still
///    counts as a match — the same shape `MessagesSingleConsumerTests` documents for `.messages`.
/// 2. **`Tests/` is not scanned.** Both walks below cover `Sources` and `Vendor` only, so
///    `GitFixtures.swift` and `FakeClaudeSpawnLogTests.swift` — which do construct a `Process()`
///    and call `.waitUntilExit()`, deliberately, to build test fixtures — are invisible to it,
///    even though the opening line above says "in this package," and `Tests/` is in the package.
/// 3. **The sanction keys on `lastPathComponent`.** A second file sharing `ChildProcess.swift`'s
///    or `IPCClient.swift`'s bare name, anywhere else under the two scanned roots, would inherit
///    its sanction unreviewed.
/// 4. **The match is a literal substring, not a parse.** `Process(\n)` split across lines, or a
///    call through `Process.launchedProcess(...)`, contains neither `"Process()"` nor
///    `".waitUntilExit()"` and would pass unseen.
@Suite("One spawner")
struct OneSpawnerTests {
    /// Walks up from this file to the package root, so the test does not depend on the working
    /// directory `swift test` happened to be run from.
    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)          // …/Tests/ElliotProcessTests/OneSpawnerTests.swift
            .deletingLastPathComponent()          // …/Tests/ElliotProcessTests
            .deletingLastPathComponent()          // …/Tests
            .deletingLastPathComponent()          // …/ElliotKit
    }

    static func swiftFiles(under directory: String) -> [URL] {
        let root = packageRoot.appendingPathComponent(directory)
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil
        ) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// A line with its comment forms stripped, so a gate about code cannot be tripped — or
    /// satisfied — by prose describing it. Copied verbatim from `DrainDuplicationTests`.
    private static func isCode(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.hasPrefix("//") && !trimmed.isEmpty
    }

    private static func lines(of file: URL) throws -> [String] {
        try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
    }

    /// Empty, and it must stay empty. Task 5 removed the last three — `Client` now speaks through
    /// the `Transport` protocol it already declared, and `ProcessManager.swift`, `ProcessRegistry.swift`
    /// and `ShellEnvironment.swift` are deleted rather than merely unreferenced.
    static let knownRemaining: Set<String> = []

    /// Files sanctioned to construct a `Process()` directly, each with its reason.
    ///
    /// Permanent, unlike `knownRemaining`. The rule this guard enforces is narrower than "nothing
    /// else spawns": **anything whose output we read, or whose exit we await, goes through
    /// `ChildProcess`.** A launcher that produces no output and whose exit status means nothing is
    /// not that, and routing it through the pipe-draining machinery would buy nothing.
    ///
    /// Adding an entry here is a deliberate act with a stated reason — which is the point. A new
    /// spawner that just appears is what #146 cost three defects.
    static let sanctionedSpawners: [String: String] = [
        "ChildProcess.swift": """
            The one spawner: drains both pipes under a single lock and publishes the exit.
            """,
        "IPCClient.swift": """
            `open -g -j -b <bundle>` to launch the app. Fire-and-forget: no pipes, and `open` exits \
            as soon as it has handed the launch to the system, so its status says nothing. Predates \
            this guard (2026-08-04) and already declines `waitUntilExit()` in its own comment, for \
            exactly the cooperative-thread reason this guard's second test exists.
            """,
    ]

    @Test("only ChildProcess.swift constructs a Process")
    func onlyOneSpawner() throws {
        var offenders: [String] = []
        for file in Self.swiftFiles(under: "Sources") + Self.swiftFiles(under: "Vendor") {
            let name = file.lastPathComponent
            guard Self.sanctionedSpawners[name] == nil,
                !Self.knownRemaining.contains(name)
            else { continue }
            let hit = try Self.lines(of: file).contains { Self.isCode($0) && $0.contains("Process()") }
            if hit { offenders.append(name) }
        }
        #expect(
            offenders.isEmpty,
            """
            \(offenders.joined(separator: ", ")) spawns a child directly — route it through \
            ChildProcess, or add it to sanctionedSpawners with the reason it does not need to \
            (see #146)
            """
        )
    }

    @Test("nothing waits on waitUntilExit")
    func nothingBlocksOnWaitUntilExit() throws {
        var offenders: [String] = []
        for file in Self.swiftFiles(under: "Sources") + Self.swiftFiles(under: "Vendor") {
            let name = file.lastPathComponent
            guard !Self.knownRemaining.contains(name) else { continue }
            // `ChildProcess`'s own doc comment explains at length why it does NOT call this, so
            // the match must be a call (leading dot) rather than a mention (no receiver).
            let hit = try Self.lines(of: file).contains {
                Self.isCode($0) && $0.contains(".waitUntilExit()")
            }
            if hit { offenders.append(name) }
        }
        #expect(
            offenders.isEmpty,
            """
            \(offenders.joined(separator: ", ")) waits on waitUntilExit(), which spins a run loop on \
            a cooperative thread the runtime may park and reuse (3b1c226/#18)
            """
        )
    }
}
