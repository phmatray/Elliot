import Foundation
import Testing

@testable import ElliotModel

@Suite("A git tree answers three ways")
struct RepoTreeTests {

    @Test("A path present is present")
    func present() {
        let t = RepoTree(paths: [".editorconfig"], truncated: false)
        #expect(t.contains(".editorconfig") == true)
    }

    @Test("A path absent from a complete tree is absent")
    func absentFromComplete() {
        let t = RepoTree(paths: ["README.md"], truncated: false)
        #expect(t.contains(".editorconfig") == false)
    }

    /// The case the shell pipeline threw away. A path not found in a truncated
    /// list proves nothing, and answering `false` here files a card — which on
    /// this board spends an unattended agent run.
    @Test("A path absent from a truncated tree is unknowable")
    func absentFromTruncated() {
        let t = RepoTree(paths: ["README.md"], truncated: true)
        #expect(t.contains(".editorconfig") == nil)
    }

    @Test("A path present in a truncated tree is still present")
    func presentInTruncated() {
        let t = RepoTree(paths: [".editorconfig"], truncated: true)
        #expect(t.contains(".editorconfig") == true)
    }

    /// Enumeration is where truncation actually bites: a monorepo whose cut
    /// falls before `.github/workflows/` yields an empty set, which reads as
    /// "this repository has no CI".
    @Test("Enumeration over a truncated tree refuses to answer")
    func enumerationRefusesWhenTruncated() {
        let t = RepoTree(paths: ["src/a.cs"], truncated: true)
        #expect(t.paths(withPrefix: ".github/workflows/") == nil)
    }

    @Test("Enumeration over a complete tree returns the matches")
    func enumerationOverComplete() {
        let t = RepoTree(
            paths: [".github/workflows/ci.yml", ".github/workflows/release.yml", "README.md"],
            truncated: false)
        #expect(t.paths(withPrefix: ".github/workflows/")?.count == 2)
    }

    /// The keys are part of a format a later plan persists, so they are pinned
    /// here rather than left to whatever the property happens to be called.
    @Test("A tree encodes under the names of the things, not the storage")
    func encodesUnderStableKeys() throws {
        let data = try JSONEncoder().encode(RepoTree(paths: ["README.md"], truncated: true))
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object.keys.sorted() == ["paths", "truncated"])

        let back = try JSONDecoder().decode(RepoTree.self, from: data)
        #expect(back.contains("README.md") == true)
        #expect(back.isTruncated)
    }
}
