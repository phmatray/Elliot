import ElliotModel
import Foundation
import Testing

@testable import ElliotEngine

@Suite("Repo tree scanner")
struct RepoTreeScannerTests {

    @Test("Only owner/visibility/name directories holding a .git are returned")
    func scansOwnerFoldersOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tree-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }

        for relative in [
            "phmatray/private/Koine/.git",  // in
            "phmatray/public/lenia/.git",  // in
            "Atypical-Consulting/public/Koine/.git",  // in — same name, other owner
            "phmatray/private/NotARepo",  // no .git
            "_worktrees/Elliot/.git",  // sibling root
            "_local-only/Yendor/.git",  // sibling root
            "repo-audit/.git",  // sibling root
            "phmatray/private/Koine/sub/.git",  // too deep
        ] {
            try FileManager.default.createDirectory(
                atPath: root + "/" + relative,
                withIntermediateDirectories: true)
        }

        let layout = RepoTreeLayout(root: root, owners: ["phmatray", "Atypical-Consulting"])
        #expect(
            RepoTreeScanner(layout: layout).scan().map(\.nameWithOwner).sorted()
                == ["Atypical-Consulting/Koine", "phmatray/Koine", "phmatray/lenia"])
    }

    @Test("A missing root is an empty scan, not a crash")
    func missingRoot() {
        let layout = RepoTreeLayout(root: "/nope/\(UUID().uuidString)", owners: ["phmatray"])
        #expect(RepoTreeScanner(layout: layout).scan().isEmpty)
    }

    @Test("The root check fails when no owner folder exists, and names the command it used")
    func rootCheck() {
        let missing = RepoTreeLayout(root: "/nope/\(UUID().uuidString)", owners: ["phmatray"])
        let result = PreflightService.repositoriesRootCheck(missing)
        #expect(result.status == .fail)
        #expect(result.command?.contains(missing.root) == true)
        #expect(result.fixHint != nil)
    }
}
