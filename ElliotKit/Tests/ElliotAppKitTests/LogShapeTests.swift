import ACPModel
import ElliotModel
import ElliotProcess
import Foundation
import TestSupport
import Testing

@testable import ElliotAppKit

/// Two log formats live in `runs/` at once, and the panel has to tell them apart.
///
/// Every run written before Stage 1 of #379 is `claude -p --output-format stream-json`; every run
/// written after it is the JSON-RPC the ACP adapter sent. Nothing renames the files and nothing
/// records the format in the database, so **the file is the only thing that knows** — which is
/// deliberate, since a log copied out of `runs/` and read by hand keeps its answer with it.
///
/// The fixtures are the same ones the live path is driven by, for the reason `RunEventMapperTests`
/// states: a test built on hand-written `RunEvent`s would pass with the decoder broken.
@Suite("Log shape")
struct LogShapeTests {
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ElliotAppKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // ElliotKit
            .deletingLastPathComponent()  // repository root
    }

    static func fixtureURL(_ relative: String) -> URL {
        repositoryRoot.appendingPathComponent("Fixtures/\(relative)")
    }

    /// Every JSON-RPC message in a probe dump, in order, as the bytes of one line each.
    ///
    /// Responses are kept as well as notifications, because the log's mirror keeps them: it is the
    /// adapter's raw stdout. A reader that mistook a response for a frame would fold a row out of
    /// `initialize`, so writing them is what makes their absence from the rows evidence.
    static func lines(inDump fixture: String) throws -> [Data] {
        let raw = try Data(contentsOf: fixtureURL("acp/\(fixture)"))
        let messages = try JSONSerialization.jsonObject(with: raw) as? [Any] ?? []
        return try messages.map { try JSONSerialization.data(withJSONObject: $0) }
    }

    /// The events the **live** path would have produced from the same dump.
    static func liveEvents(inDump fixture: String) throws -> [RunEvent] {
        let raw = try Data(contentsOf: fixtureURL("acp/\(fixture)"))
        let messages = try JSONSerialization.jsonObject(with: raw) as? [[String: Any]] ?? []
        var events: [RunEvent] = []
        for message in messages where message["method"] as? String == "session/update" {
            let params = try JSONSerialization.data(withJSONObject: message["params"] as Any)
            let note = try JSONDecoder().decode(SessionUpdateNotification.self, from: params)
            events.append(contentsOf: RunEventMapper.events(from: note))
        }
        return events
    }

    static func run(logPath: String) -> SkillRun {
        SkillRun(
            cardID: UUID(),
            repoID: UUID(),
            kind: .createIssue,
            prompt: "story",
            cwd: "/tmp",
            state: .succeeded,
            logPath: logPath,
            stderrPath: logPath + ".err",
            createdAt: Date()
        )
    }

    static func write(_ lines: [Data], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var file = Data()
        for line in lines {
            file.append(line)
            file.append(0x0A)
        }
        try file.write(to: url)
    }

    // MARK: - The discriminator

    @Test("a stream-json log and an ACP log are told apart by their first line")
    func theTwoLogShapes() throws {
        let home = TestHome.scratch("log-shape")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let acp = home.appendingPathComponent("acp.jsonl")
        try Self.write(Self.lines(inDump: "turn-edit-bash.json"), to: acp)
        #expect(RunsPane.shape(ofLogAt: acp.path) == .acp)

        let streamJSON = home.appendingPathComponent("stream.jsonl")
        try Data(contentsOf: Self.fixtureURL("stream-json/create-issue-success.ndjson"))
            .write(to: streamJSON)
        #expect(RunsPane.shape(ofLogAt: streamJSON.path) == .streamJSON)

        // Elliot's own records are JSON-RPC too, so a log whose first line is one — which is what
        // a log written by a future writer that recorded the session before the mirror opened
        // would look like — is still ACP.
        let elliotFirst = home.appendingPathComponent("elliot-first.jsonl")
        let info = RunSessionInfo(agentSessionID: "s-1", cwd: "/tmp")
        try Self.write([AgentLog.sessionLine(info)], to: elliotFirst)
        #expect(RunsPane.shape(ofLogAt: elliotFirst.path) == .acp)

        // Blank lines are skipped rather than answered.
        let leadingBlanks = home.appendingPathComponent("blanks.jsonl")
        try Data("\n\n{\"type\":\"system\",\"subtype\":\"init\"}\n".utf8).write(to: leadingBlanks)
        #expect(RunsPane.shape(ofLogAt: leadingBlanks.path) == .streamJSON)

        // Three ways to have no answer, and all three are the same absence.
        let empty = home.appendingPathComponent("empty.jsonl")
        try Data().write(to: empty)
        #expect(RunsPane.shape(ofLogAt: empty.path) == nil)

        let garbage = home.appendingPathComponent("garbage.jsonl")
        try Data("not json at all\n".utf8).write(to: garbage)
        #expect(RunsPane.shape(ofLogAt: garbage.path) == nil)

        #expect(RunsPane.shape(ofLogAt: home.appendingPathComponent("absent.jsonl").path) == nil)

        // ⚠️ A log with neither answer still renders, and **the pin here is the expression rather
        // than the assertion**: `.rows` on the result compiles only while `diskRows` returns a
        // window rather than an optional one. That is the whole difference the panel reads —
        // `RunBox.emptyNote` treats a nil `diskRows` as *not opened yet* and says "Reading the
        // log…", so a pruned log (`ArtifactSweeper`, #167) would report a read still in progress
        // for ever. `emptyNote` is private to a `View` and unreachable from here; the return type
        // is the part of that guarantee a test can hold.
        let run = Self.run(logPath: empty.path)
        let window: RunsPane.LogWindow = RunsPane.diskRows(at: empty.path, run: run)
        #expect(window.rows.isEmpty)
        #expect(window.dropped == 0)
    }

    // MARK: - The ACP half

    @Test("an ACP log on disk folds into the same rows the live tail produces")
    func diskAndLiveAgree() throws {
        let home = TestHome.scratch("log-shape-acp")
        defer { try? FileManager.default.removeItem(at: home) }

        let info = RunSessionInfo(
            agentSessionID: "1401310e-142a-45f0-a86b-b6dba23c08c0",
            agentName: "@agentclientprotocol/claude-agent-acp", agentVersion: "0.66.0",
            cwd: "/private/tmp/elliot-acp-sandbox", model: "claude-opus-5", mode: "bypassPermissions"
        )
        let summary = TurnSummary(
            stopReason: "end_turn", text: "Done.", inputTokens: 12, outputTokens: 34,
            totalTokens: 46, isError: false
        )

        let log = home.appendingPathComponent("runs/acp.jsonl")
        var lines = [AgentLog.sessionLine(info)]
        lines.append(contentsOf: try Self.lines(inDump: "turn-edit-bash.json"))
        lines.append(AgentLog.terminalLine(summary))
        try Self.write(lines, to: log)

        let run = Self.run(logPath: log.path)
        let live = RunsPane.rows(
            of: run,
            events: [.session(info)] + (try Self.liveEvents(inDump: "turn-edit-bash.json")),
            summary: summary
        )
        let disk = RunsPane.diskRows(at: log.path, run: run)

        #expect(disk == live)
        // Named, so a run of two empty windows cannot pass as agreement.
        #expect(!disk.rows.isEmpty)

        // The two rows the fold is actually for: the handshake Elliot wrote itself, and the turn
        // it ended with — neither of which is a `session/update` frame.
        let openedSession = disk.rows.contains {
            if case .agentSession(let seen) = $0 { return seen == info }
            return false
        }
        #expect(openedSession)
        let ended = disk.rows.contains {
            if case .turnEnded(let seen) = $0 { return seen.stopReason == "end_turn" }
            return false
        }
        #expect(ended)

        // The `Edit` call survives its six frames on disk exactly as it does live: a replacing
        // fold leaves this row with no title and no kind.
        let edit = disk.rows.compactMap { row -> ToolCallPatch? in
            guard case .toolCall(let call) = row,
                call.id == "toolu_01Lf1nZmGFgp68y1sbgi8fpb"
            else { return nil }
            return call
        }
        #expect(edit.count == 1)
        #expect(edit.first?.title == "Edit /private/tmp/elliot-acp-sandbox/notes.txt")
        #expect(edit.first?.status == .completed)
    }

    /// A refused call reaches the archive with the kind that refused it — §5.4 asks for the value
    /// to reach the log *and* the card, and a log that folds it away answers only the second half.
    @Test("a refusal keeps its nonExecutionKind through the disk fold")
    func theRefusalSurvivesTheDiskFold() throws {
        let home = TestHome.scratch("log-shape-refusal")
        defer { try? FileManager.default.removeItem(at: home) }

        let log = home.appendingPathComponent("runs/refusal.jsonl")
        try Self.write(try Self.lines(inDump: "turn-refusal.json"), to: log)

        let run = Self.run(logPath: log.path)
        let rows = RunsPane.diskRows(at: log.path, run: run).rows
        let refused = rows.compactMap { row -> NonExecutionKind? in
            guard case .toolCall(let call) = row else { return nil }
            return call.nonExecutionKind
        }
        #expect(refused.contains(.permissionRule))
    }

    // MARK: - The stream-json half

    @Test("a stream-json log still folds exactly as it did")
    func theArchiveIsUnchanged() throws {
        let home = TestHome.scratch("log-shape-archive")
        defer { try? FileManager.default.removeItem(at: home) }

        let log = home.appendingPathComponent("runs/stream.jsonl")
        try FileManager.default.createDirectory(
            at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: Self.fixtureURL("stream-json/create-issue-success.ndjson"))
            .write(to: log)

        let run = Self.run(logPath: log.path)
        let rows = RunsPane.diskRows(at: log.path, run: run).rows

        // Against the fold the archive had before the discriminator existed, so "unchanged" is
        // measured rather than asserted.
        #expect(
            RunsPane.diskRows(at: log.path, run: run)
                == RunsPane.rows(of: run, events: RunBox.diskEvents(at: log.path)))

        // And named, because two empty windows are also equal.
        let opened = rows.contains { if case .session = $0 { return true } else { return false } }
        #expect(opened)
        let terminal = rows.contains {
            if case .terminal = $0 { return true } else { return false }
        }
        #expect(terminal)
        // ⛔ Not an ACP row anywhere: those are what a misrouted stream-json log would produce.
        let acpRows = rows.contains {
            switch $0 {
            case .agentSession, .turnEnded, .toolCall, .thought, .plan, .modeChanged: true
            default: false
            }
        }
        #expect(!acpRows)
    }
}
