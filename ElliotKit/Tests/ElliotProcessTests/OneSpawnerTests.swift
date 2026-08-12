import Foundation
import Testing

/// `ChildProcess` is the only thing in this package that starts a child, drains its pipes and
/// publishes its exit. That was true until a vendored ACP library arrived carrying three more
/// spawners — one of which called `waitUntilExit()`, which this repository's production rule
/// forbids outright.
///
/// #146 is why this is a test and not a comment: the mechanism was written twice before, eight
/// comment lines were byte-identical across the two copies, and three defects were each fixed in
/// one file only. A vendor boundary is a worse place for that to happen, not a better one.
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

    /// The three files Task 5 removes, once `Client` no longer references them.
    ///
    /// They are one dependency chain — `Client` → `ProcessManager` → `ShellEnvironment` — so none
    /// can go before the others. `ShellEnvironment.swift` is here for the second guard rather than
    /// the first: it calls `waitUntilExit()`.
    ///
    /// Listed by name so the guard is **armed now** and this set emptying is Task 5's acceptance
    /// criterion — which is not the same thing as a guard switched off and forgotten.
    static let knownRemaining: Set<String> = [
        "ProcessManager.swift", "ProcessRegistry.swift", "ShellEnvironment.swift",
    ]

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
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("Process()") { offenders.append(name) }
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
            let text = try String(contentsOf: file, encoding: .utf8)
            // `ChildProcess`'s own doc comment explains at length why it does NOT call this, so
            // the match must be a call rather than a mention.
            if text.contains(".waitUntilExit()") { offenders.append(name) }
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
