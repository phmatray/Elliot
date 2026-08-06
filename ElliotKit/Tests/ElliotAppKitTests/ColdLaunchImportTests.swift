import ElliotEngine
import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import TestSupport
import Testing

@testable import ElliotAppKit

/// #120: on a cold launch with a repository already registered, the automatic
/// import never ran.
///
/// `AppModel.start()` publishes a selection one local database read after
/// launch — `observe(store:)` is deliberately hoisted above the login-shell
/// capture so the board stops claiming "No repository yet" through the whole of
/// startup. But `importer` cannot be built until *after* that capture and three
/// tool lookups, because it needs the located `gh`. So `BoardView`'s
/// `.task(id: selectedRepoID)` fires against a nil importer, returns, and never
/// runs again: `.task(id:)` re-runs on an id *change*, and the id does not
/// change twice.
///
/// The property that makes the fix safe is the one asserted here: **a call that
/// cannot import must not spend the session's one unattended attempt.** Then it
/// does not matter which of the two racers wins — whichever arrives second does
/// the work, and the session guard keeps it to exactly one import either way.
@Suite("Cold launch import")
@MainActor
struct ColdLaunchImportTests {

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
        private(set) var launched: [UUID] = []
        func launch(runID: UUID) async { launched.append(runID) }
        func cancel(runID: UUID) async {}
    }

    /// A model holding a real store and a real repository, with **no importer**
    /// — the state `start()` is in while it waits on the shell capture.
    private func coldModel() async throws -> (AppModel, BoardStore, Repo) {
        let store = try BoardStore.inMemory()
        let repo = Repo(
            path: "/tmp/elliot-\(UUID().uuidString)",
            nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        try await store.saveRepo(repo)

        let model = AppModel()
        model.testOnlySeed(repos: [repo], cards: [])
        model.testOnlySeedStore(store)
        model.selectedRepoID = repo.id
        return (model, store, repo)
    }

    private func importer(
        _ store: BoardStore, mode: String = "ok", issues: String? = "issues-basic.json"
    ) -> GitHubImportService {
        var environment = ["FAKE_GH_MODE": mode]
        if let issues { environment["FAKE_GH_ISSUES"] = Paths.fixture(issues) }
        environment["FAKE_GH_PRS"] = Paths.fixture("prs-basic.json")
        let config = ToolConfig(
            claudePath: "", ghPath: Paths.fakeGH, gitPath: "", environment: environment)
        return GitHubImportService(
            store: store,
            gh: GHClient(config: config),
            board: BoardService(store: store, launcher: SilentLauncher()))
    }

    // MARK: - The bug

    /// The regression test. Before the fix this failed on the second call:
    /// the first spent nothing (the guard returns before recording), but
    /// nothing ever called it again, so on a real launch the import simply
    /// never happened. Asserting the *retry works* is what pins the fix.
    @Test("A selection that arrives before the importer does not lose the import")
    func earlySelectionDoesNotLoseTheImport() async throws {
        let (model, store, repo) = try await coldModel()

        // The view's `.task(id:)` firing while `start()` is still locating `gh`.
        try await withTimeout(.seconds(30)) { await model.importIfNeeded(repoID: repo.id) }
        #expect(try await store.cards(repoID: repo.id).isEmpty, "nothing could be imported yet")

        // …and now the importer exists, as it does at the end of `start()`.
        model.testOnlyAttachImporter(importer(store))
        try await withTimeout(.seconds(30)) { await model.importIfNeeded(repoID: repo.id) }

        #expect(
            try await store.cards(repoID: repo.id).count == 3,
            "the attempt was not spent by the call that could not import")
    }

    /// Criterion 3, and the trap in fixing this: the guard must still stop a
    /// second unattended import.
    @Test("Once the import has happened, the unattended path does not repeat it")
    func stillExactlyOncePerSession() async throws {
        let (model, store, repo) = try await coldModel()
        model.testOnlyAttachImporter(importer(store))

        try await withTimeout(.seconds(30)) { await model.importIfNeeded(repoID: repo.id) }
        let afterFirst = try await store.cards(repoID: repo.id)
        #expect(afterFirst.count == 3)

        for _ in 0..<5 {
            try await withTimeout(.seconds(30)) { await model.importIfNeeded(repoID: repo.id) }
        }

        let afterMany = try await store.cards(repoID: repo.id)
        #expect(afterMany.count == 3, "five more unattended calls changed nothing")
        #expect(Set(afterMany.map(\.id)) == Set(afterFirst.map(\.id)), "and nothing was replaced")
    }

    /// Criterion 4 — #42's rule. A launch whose import genuinely cannot run has
    /// to say so; an empty board that means "I could not ask" must not look
    /// like one that means "there is nothing here".
    @Test("A launch whose import fails says so, rather than showing a silent empty board")
    func failureIsVisibleAfterAColdLaunch() async throws {
        let (model, store, repo) = try await coldModel()
        model.testOnlyAttachImporter(importer(store, mode: "fail"))

        try await withTimeout(.seconds(30)) { await model.importIfNeeded(repoID: repo.id) }

        #expect(model.importFailure(repoID: repo.id) != nil)
        #expect(model.visibleImportFailures.count == 1)
        #expect(try await store.cards(repoID: repo.id).isEmpty)
    }

    /// The other order, which the fix also has to survive: the repositories
    /// arrive *late*, so the bootstrap's own call finds no selection and the
    /// view's `.task` is the one that does the work.
    @Test("A selection that arrives after the importer is imported by the view")
    func lateSelectionStillImports() async throws {
        let (model, store, repo) = try await coldModel()
        model.selectedRepoID = nil
        model.testOnlyAttachImporter(importer(store))

        // `start()` reaching its import with nothing selected yet.
        try await withTimeout(.seconds(30)) { await model.importIfNeeded(repoID: model.selectedRepoID) }
        #expect(try await store.cards(repoID: repo.id).isEmpty)

        // The observation delivers, the id changes, `.task(id:)` fires.
        model.selectedRepoID = repo.id
        try await withTimeout(.seconds(30)) { await model.importIfNeeded(repoID: repo.id) }

        #expect(try await store.cards(repoID: repo.id).count == 3)
    }

    @Test("A repository that is not enabled is never imported by either path")
    func disabledIsNeverImported() async throws {
        let store = try BoardStore.inMemory()
        let repo = Repo(
            path: "/tmp/elliot-\(UUID().uuidString)",
            nameWithOwner: "phmatray/Elliot", displayName: "Elliot",
            isEnabled: false)
        try await store.saveRepo(repo)

        let model = AppModel()
        model.testOnlySeed(repos: [repo], cards: [])
        model.testOnlySeedStore(store)
        model.testOnlyAttachImporter(importer(store))

        try await withTimeout(.seconds(30)) { await model.importIfNeeded(repoID: repo.id) }
        #expect(try await store.cards(repoID: repo.id).isEmpty)
    }
}
