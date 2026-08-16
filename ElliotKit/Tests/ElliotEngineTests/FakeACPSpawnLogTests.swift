import Foundation
import Testing

/// `FAKE_ACP_PROMPT_OUT` truncates, so it records only the last turn — a run started twice looks
/// exactly like a run started once. Counting spawns is the whole question in the concurrent-pump
/// tests, so the double needs a sink that accumulates.
///
/// ⚠️ **This was `FakeClaudeSpawnLogTests`, and what it drives moved from argv to the wire.**
/// `fake-claude.sh` read the prompt out of `-p <text>` at start-up and could log it before doing
/// anything else; `fake-acp.py` only learns the prompt when `session/prompt` arrives, so the line
/// is written there. The knob therefore counts **turns asked for** rather than processes started —
/// see the double's own docstring for why that is the useful reading rather than a compromise.
@Suite("fake-acp — spawn log")
struct FakeACPSpawnLogTests {

    private static let script: String = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ElliotEngineTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // ElliotKit
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("Scripts/fake-acp.py").path

    /// Drives one whole conversation and waits for the double to exit.
    ///
    /// The three requests are written in one go and stdin is then closed: the double reads line by
    /// line and answers in order, so `session/new` has issued its session id by the time
    /// `session/prompt` is read. Closing stdin is what ends it — `read_message` returns nil on EOF
    /// and the main loop breaks — which is why nothing here waits on a duration.
    private func invoke(prompt: String, log: String) throws {
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}"#,
            // `prompt`, which is what `SessionPromptRequest` puts on the wire.
            {
                let escaped = String(
                    decoding: try! JSONSerialization.data(
                        withJSONObject: [prompt], options: [.fragmentsAllowed]),
                    as: UTF8.self)
                // `[["…"]]` → the element, without re-implementing JSON string escaping here.
                let text = String(escaped.dropFirst().dropLast())
                return #"{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":"#
                    + #"{"sessionId":"sess-fake-0001","prompt":[{"type":"text","text":"# + text + "}]}}"
            }(),
        ].joined(separator: "\n") + "\n"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", Self.script]
        process.environment = ["FAKE_ACP_SPAWN_LOG": log, "PATH": "/usr/bin:/bin"]
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(Data(requests.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
    }

    @Test("Two turns append two lines, one per turn")
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
