import ElliotEngine
import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotAppKit

/// The banner's Retry means the repository the row names.
///
/// It re-imported **every** repository whenever the picker said "All
/// repositories" — serially, with `isImporting` disabling every other row's
/// Retry for the duration. The banner exists precisely because a failure written
/// into `status` was overwritten seconds later; a Retry that touches everything
/// undoes half of that scoping.
@Suite("Scoped retry", .serialized)
@MainActor
struct ScopedRetryTests {

    private enum Paths {
        static let repoRoot: URL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ElliotAppKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ElliotKit
            .deletingLastPathComponent()   // repo root

        static let fakeGH = repoRoot.appendingPathComponent("Scripts/fake-gh.sh").path

        static func fixture(_ name: String) -> String {
            repoRoot.appendingPathComponent("Fixtures/gh/\(name)").path
        }
    }

    private actor SilentLauncher: RunLaunching {
        func launch(runID: UUID) async {}
        func cancel(runID: UUID) async {}
    }

    /// A model holding two repositories and an importer whose every `gh`
    /// invocation is appended to one file. The argv log is the measurement:
    /// counting summaries would only say how many the *model* recorded, and the
    /// claim is about which repositories were asked about at all.
    private func twoRepoModel() async throws -> (AppModel, Repo, Repo, String) {
        let store = try BoardStore.inMemory()
        let first = Repo(
            path: "/tmp/one-\(UUID().uuidString)",
            nameWithOwner: "phmatray/One", displayName: "One")
        let second = Repo(
            path: "/tmp/two-\(UUID().uuidString)",
            nameWithOwner: "phmatray/Two", displayName: "Two")
        try await store.saveRepo(first)
        try await store.saveRepo(second)

        let argv = FileManager.default.temporaryDirectory
            .appendingPathComponent("argv-\(UUID().uuidString).txt").path
        let config = ToolConfig(
            ghPath: Paths.fakeGH, gitPath: "",
            environment: [
                "FAKE_GH_MODE": "ok",
                "FAKE_GH_ISSUES": Paths.fixture("issues-basic.json"),
                "FAKE_GH_PRS": Paths.fixture("prs-basic.json"),
                "FAKE_GH_ARGV_OUT": argv,
            ])

        let model = AppModel()
        model.testOnlySeed(repos: [first, second], cards: [])
        model.testOnlySeedStore(store)
        model.testOnlyAttachImporter(
            GitHubImportService(
                store: store, gh: GHClient(config: config),
                board: BoardService(store: store, launcher: SilentLauncher())))
        // "All repositories" — the state in which the bug fired.
        model.selectedRepoID = nil
        return (model, first, second, argv)
    }

    private func argvLog(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    /// ⛔ The defect. With "All repositories" chosen, one row's Retry imported
    /// both.
    @Test("Retrying one repository asks gh about that repository only")
    func retryIsScopedToItsRow() async throws {
        let (model, first, second, argv) = try await twoRepoModel()

        await model.refreshFromGitHub(repoID: second.id)

        let log = argvLog(argv)
        #expect(log.contains("phmatray/Two"))
        #expect(log.contains("phmatray/One") == false)
        #expect(model.status.contains("Two") || model.status.isEmpty == false)
        _ = first
    }

    /// The toolbar's Refresh is unchanged: no id, so it still means whatever the
    /// picker is showing.
    @Test("With no id and no selection, every repository is still refreshed")
    func theWholeBoardStillRefreshes() async throws {
        let (model, _, _, argv) = try await twoRepoModel()

        await model.refreshFromGitHub()

        let log = argvLog(argv)
        #expect(log.contains("phmatray/One"))
        #expect(log.contains("phmatray/Two"))
    }

    /// An id overrides the picker rather than intersecting with it: the banner is
    /// scoped to what the picker shows, so a row a reader can see is a row whose
    /// button must mean that row.
    @Test("An id wins over the picker's selection")
    func idOverridesTheSelection() async throws {
        let (model, first, second, argv) = try await twoRepoModel()
        model.selectedRepoID = first.id

        await model.refreshFromGitHub(repoID: second.id)

        let log = argvLog(argv)
        #expect(log.contains("phmatray/Two"))
        #expect(log.contains("phmatray/One") == false)
    }

    /// ⛔ An id naming no repository is **not** "no filter" — the collapse four
    /// MCP tools each had to be taught separately, which here would turn one
    /// row's Retry into a whole-board import. And it is not silent either: the
    /// button was pressed on purpose.
    ///
    /// ⚠️ The empty log is only evidence **because the sibling tests above show
    /// the log fills**. On its own it is the weakest kind of assertion — a
    /// mis-pointed `ghPath` produces exactly the same emptiness, which is what
    /// happened while writing these: `Scripts/` is at the repository root, not
    /// under `ElliotKit`, and every log came back blank. The status sentence is
    /// the positive witness that this path ran at all.
    @Test("An unknown repository imports nothing, and says so")
    func anUnknownIdIsRefusedRatherThanWidened() async throws {
        let (model, _, _, argv) = try await twoRepoModel()

        await model.refreshFromGitHub(repoID: UUID())

        #expect(model.status.contains("no longer on the board"))
        #expect(argvLog(argv).isEmpty)
    }
}
