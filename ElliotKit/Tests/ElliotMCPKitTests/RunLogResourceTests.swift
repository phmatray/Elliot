import ElliotIPC
import ElliotModel
import ElliotStore
import Foundation
import MCP
import TestSupport
import Testing

@testable import ElliotMCPKit

/// Reading a run's transcript back off disk.
///
/// Written where `StoreLocation` says: the coupling being pinned is exactly
/// that the reader computes the same path the writer did — `RunLogPathTests`
/// holds up the other end — so writing anywhere else would test nothing. Each
/// file is named by a fresh UUID and removed after.
///
/// `ELLIOT_HOME` is not redirected here, but it *is* pinned before any path is
/// resolved, by touching `TestHome.root`. This suite shares a process with ones
/// that spawn real runs — SwiftPM links every test target into one bundle — and
/// those set the variable from a lazy static. Leaving it alone was not the same
/// as leaving it stable: this suite wrote a file under one home and then read it
/// under another, and reported its own log missing.
@Suite("The run log as a resource")
struct RunLogResourceTests {

    /// Settles `ELLIOT_HOME` before the first path is computed. Idempotent, and
    /// called from every helper below rather than once somewhere clever: Swift
    /// Testing gives a suite no "before all", so the guarantee has to be one
    /// each entry point can restate cheaply.
    private func pinHome() {
        _ = TestHome.root
    }

    private func writeLog(_ text: String, for runID: UUID) throws {
        pinHome()
        try StoreLocation.ensureDirectories()
        try Data(text.utf8).write(to: StoreLocation.runLogURL(runID: runID))
    }

    private func removeLog(_ runID: UUID) {
        pinHome()
        try? FileManager.default.removeItem(at: StoreLocation.runLogURL(runID: runID))
    }

    private func read(_ runID: UUID) async throws -> Resource.Content {
        pinHome()
        let store = try await makeStore()
        let result = try await ElliotMCPServer(bridge: StubBridge.snapshot(store))
            .readResource(uri: "elliot://run/\(runID.uuidString)/log")
        return try #require(result.contents.first)
    }

    @Test("A run's log comes back as the NDJSON the CLI wrote")
    func logIsServedVerbatim() async throws {
        let runID = UUID()
        defer { removeLog(runID) }
        let lines = """
            {"type":"system","subtype":"init"}
            {"type":"assistant","text":"filing the issue"}
            {"type":"result","subtype":"success"}
            """
        try writeLog(lines + "\n", for: runID)

        let content = try await read(runID)

        #expect(content.mimeType == "application/x-ndjson")
        #expect(content.text == lines + "\n")
        #expect(content._meta?["truncated"]?.boolValue == false)
        #expect(content._meta?["line_boundary"]?.boolValue == true)
    }

    @Test("A run id with no log says so rather than answering with nothing")
    func missingLogIsRefused() async throws {
        // An empty document reads as "this run emitted nothing", which is a
        // different statement from "there is no such file".
        await #expect(throws: MCPError.self) {
            _ = try await read(UUID())
        }
    }

    @Test("A log too large to serve is cut to whole events, and says it was cut")
    func largeLogIsTailedOnALineBoundary() async throws {
        let runID = UUID()
        defer { removeLog(runID) }
        let event = #"{"type":"assistant","text":"\#(String(repeating: "x", count: 200))"}"#
        let lines = (0..<3000).map { "\(event)\($0)" }.joined(separator: "\n") + "\n"
        #expect(lines.utf8.count > ElliotMCPServer.logTailLimit)
        try writeLog(lines, for: runID)

        let content = try await read(runID)
        let text = try #require(content.text)

        #expect(content._meta?["truncated"]?.boolValue == true)
        #expect(content._meta?["line_boundary"]?.boolValue == true)
        // Still NDJSON: every line the agent gets must parse on its own.
        #expect(text.hasPrefix("{"))
        for line in text.split(separator: "\n") {
            #expect(line.hasPrefix(#"{"type""#))
        }
        // The tail, not the head — the end of a run is what explains it.
        #expect(text.hasSuffix("}2999\n"))
    }

    @Test("A single event longer than the whole tail is said not to start on a boundary")
    func oneHugeEventReportsNoBoundary() async throws {
        // A big file read or a long tool result. There is no boundary to start
        // on, and an agent told only `truncated` would read the JSON parse error
        // on line 1 as a corrupt log rather than a clipped one.
        let runID = UUID()
        defer { removeLog(runID) }
        try writeLog(String(repeating: "x", count: ElliotMCPServer.logTailLimit * 2), for: runID)

        let content = try await read(runID)

        #expect(content._meta?["truncated"]?.boolValue == true)
        #expect(content._meta?["line_boundary"]?.boolValue == false)
        #expect(content._meta?["served_bytes"]?.intValue
            == ElliotMCPServer.logTailLimit)
    }
}
