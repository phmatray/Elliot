import Foundation
import Testing

@testable import ElliotProcess

/// `/usr/bin/true` rather than a real `gh`, following the house pattern: the
/// suite must not depend on Homebrew's layout, a token or the network. Every
/// assertion below is about a guard that fires *before* the subprocess.
private func testConfig() -> ToolConfig {
    ToolConfig(
        ghPath: "/usr/bin/true", gitPath: "/usr/bin/true",
        environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    )
}

/// A directory that looks like a clone, in the temporary directory. Nothing in
/// this suite may write under ~/Repositories.
private func makeTemporaryRepo() throws -> String {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("repo-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: path + "/.git", withIntermediateDirectories: true)
    return path
}

@Suite("Git write verbs", .serialized)
struct GitClientWriteTests {

    @Test("Relocating moves the directory, creating the destination's parent")
    func relocate() throws {
        let source = try makeTemporaryRepo()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("moved-\(UUID().uuidString)/owner/private/Koine").path
        defer {
            try? FileManager.default.removeItem(atPath: source)
            try? FileManager.default.removeItem(atPath: destination)
        }
        try GitClient(config: testConfig()).relocate(from: source, to: destination)
        #expect(FileManager.default.fileExists(atPath: destination + "/.git"))
        #expect(!FileManager.default.fileExists(atPath: source))
    }

    @Test("Relocating refuses an occupied destination, and both sides survive")
    func relocateRefusesOccupied() throws {
        let source = try makeTemporaryRepo(), destination = try makeTemporaryRepo()
        defer {
            try? FileManager.default.removeItem(atPath: source)
            try? FileManager.default.removeItem(atPath: destination)
        }
        #expect(throws: (any Error).self) {
            try GitClient(config: testConfig()).relocate(from: source, to: destination)
        }
        #expect(FileManager.default.fileExists(atPath: source + "/.git"), "nothing was moved")
        #expect(FileManager.default.fileExists(atPath: destination + "/.git"), "nothing was overwritten")
    }

    @Test("Cloning refuses a path that already exists rather than writing into it")
    func cloneRefusesOccupied() async throws {
        let occupied = try makeTemporaryRepo()
        defer { try? FileManager.default.removeItem(atPath: occupied) }
        await #expect(throws: (any Error).self) {
            try await GitClient(config: testConfig()).clone(nameWithOwner: "o/r", into: occupied)
        }
        #expect(
            FileManager.default.fileExists(atPath: occupied + "/.git"),
            "the existing clone is untouched")
    }
}
