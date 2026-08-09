import Foundation
import Testing

/// `FAKE_CLAUDE_ARGV_OUT` truncates, so it records only the last spawn — a run
/// started twice looks exactly like a run started once. Counting spawns is the
/// whole question in the concurrent-pump tests, so the fake needs a sink that
/// accumulates.
@Suite("fake-claude — spawn log")
struct FakeClaudeSpawnLogTests {

    private static let script: String = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ElliotEngineTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // ElliotKit
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("Scripts/fake-claude.sh").path

    private func invoke(prompt: String, log: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.script, "-p", prompt]
        process.environment = ["FAKE_CLAUDE_SPAWN_LOG": log, "PATH": "/usr/bin:/bin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    @Test("Two invocations append two lines, one per spawn")
    func appendsOneLinePerSpawn() throws {
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("spawn-\(UUID().uuidString).log").path
        defer { try? FileManager.default.removeItem(atPath: log) }

        try invoke(prompt: "run one", log: log)
        try invoke(prompt: "run two", log: log)

        let lines = try String(contentsOfFile: log, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines == ["run one", "run two"])
    }

    @Test("The line is the prompt's first line, so a multi-line prompt still identifies its run")
    func recordsFirstPromptLine() throws {
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("spawn-\(UUID().uuidString).log").path
        defer { try? FileManager.default.removeItem(atPath: log) }

        try invoke(prompt: "run three\nELLIOT_OUTPUT=/tmp/x", log: log)

        let lines = try String(contentsOfFile: log, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines == ["run three"])
    }
}
