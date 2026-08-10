import ElliotModel
import Foundation
import Testing

@testable import ElliotEngine

/// One resolver, two harvesters. The containment check is the reason this is
/// extracted rather than copied: a citation must stay inside the repository, and
/// the boundary has to land on a **path component** — a bare string prefix
/// admits a sibling directory like `/repo-evil` for a root of `/repo`.
@Suite("Evidence resolution")
struct EvidenceResolverTests {

    private struct Fixture {
        var root: URL
        var sibling: URL
        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sibling)
        }
    }

    /// A repository with one real file, and a sibling directory whose path
    /// shares the root's as a string prefix without being underneath it.
    private func makeFixture() throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elliot-evidence-\(UUID().uuidString)", isDirectory: true)
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "// real".write(
            to: sources.appendingPathComponent("Real.swift"), atomically: true, encoding: .utf8)

        let sibling = root.deletingLastPathComponent()
            .appendingPathComponent("\(root.lastPathComponent)-evil", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try "// secret".write(
            to: sibling.appendingPathComponent("secret.swift"), atomically: true, encoding: .utf8)

        return Fixture(root: root, sibling: sibling)
    }

    @Test("A citation inside the repository that exists is marked found")
    func insideAndPresent() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let resolved = EvidenceResolver.resolve(
            ["Sources/Real.swift:3"], repoPath: fixture.root.path)
        #expect(resolved.count == 1)
        #expect(resolved[0].path == "Sources/Real.swift")
        #expect(resolved[0].line == 3)
        #expect(resolved[0].exists)
    }

    @Test("A citation inside the repository that does not exist is marked, not dropped")
    func insideAndAbsent() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let resolved = EvidenceResolver.resolve(
            ["Sources/Nowhere.swift:9"], repoPath: fixture.root.path)
        // Marked rather than removed: a missing file is the fastest signal that
        // a citation was invented, and dropping it would hide that.
        #expect(resolved.count == 1)
        #expect(resolved[0].exists == false)
    }

    @Test("A citation escaping through a sibling directory is not inside the repository")
    func siblingEscapeIsRejected() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let escaped = "../\(fixture.root.lastPathComponent)-evil/secret.swift:1"
        let resolved = EvidenceResolver.resolve([escaped], repoPath: fixture.root.path)

        // The escaped file genuinely exists — proving the containment check, and
        // not a missing-file coincidence, is what marked this not-found.
        #expect(FileManager.default.fileExists(
            atPath: fixture.sibling.appendingPathComponent("secret.swift").path))
        #expect(resolved.count == 1)
        #expect(resolved[0].exists == false)
    }

    @Test("An unparseable citation is dropped rather than turned into a blank path")
    func unparseableIsDropped() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        #expect(EvidenceResolver.resolve(["", "   ", ":12"], repoPath: fixture.root.path).isEmpty)
    }

    @Test("The repository root itself resolves as inside")
    func theRootIsInside() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        // `resolved.path == root.path` is a separate branch from the
        // `hasPrefix(root.path + "/")` one, and only this reaches it.
        let resolved = EvidenceResolver.resolve(["."], repoPath: fixture.root.path)
        #expect(resolved.count == 1)
        #expect(resolved[0].exists)
    }
}
