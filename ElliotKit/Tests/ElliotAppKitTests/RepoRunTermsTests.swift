import ElliotModel
import ElliotStore
import Foundation
import Testing

@testable import ElliotAppKit

/// The writer `permissionMode` and `extraAllowedTools` never had.
///
/// Both are **v1** columns. `RunScheduler` reads them at spawn,
/// `ClaudeInvocation.arguments()` emits both flags, `board_list_repos` reports
/// the mode — and nothing anywhere assigned either one, so every registration
/// took `bypassPermissions` and `[]` for ever. `Repo.permissionMode`'s own doc
/// comment said a single repository could be tightened without touching the
/// others; it could not.
@Suite("Repository run terms")
struct RepoRunTermsTests {

    @MainActor
    @Test("Choosing a mode persists it and leaves the tools alone")
    func modeIsSavedNarrowly() async throws {
        let (model, store, repo) = try await seeded(tools: ["Read"])
        await model.setRunTerms(repo, .mode(.plan))

        let after = try #require(try await store.repo(id: repo.id))
        #expect(after.permissionMode == .plan)
        #expect(after.extraAllowedTools == ["Read"])
    }

    @MainActor
    @Test("A tools list is normalised before it is stored, never after")
    func toolsAreNormalisedOnTheWayIn() async throws {
        let (model, store, repo) = try await seeded(tools: [])
        await model.setRunTerms(repo, .tools([" Read ", "", "Read", "Bash(git status *)"]))

        let after = try #require(try await store.repo(id: repo.id))
        #expect(after.extraAllowedTools == ["Read", "Bash(git status *)"])
        #expect(after.permissionMode == .bypassPermissions)
    }

    /// `arguments()` emits `--allowedTools` only for a non-empty list, so `[""]`
    /// reaching the store is not "no tools" — it is an empty pattern handed to
    /// the CLI, which no screen could show and only a run would discover.
    @MainActor
    @Test("Emptying the list stores nothing, not a list holding a blank")
    func emptyingTheListStoresEmpty() async throws {
        let (model, store, repo) = try await seeded(tools: ["Read"])
        await model.setRunTerms(repo, .tools(["   "]))

        #expect(try await store.repo(id: repo.id)?.extraAllowedTools == [])
    }

    /// The screen and the spawn must not disagree about a safety control. A
    /// silent failure here leaves the row on `bypassPermissions` while the
    /// picker shows the tightened value.
    @MainActor
    @Test("A save that cannot happen says so instead of failing quietly")
    func aRefusedWriteIsAnnounced() async throws {
        let model = AppModel()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("run-terms-\(UUID().uuidString).sqlite")
        let writable = try BoardStore.open(at: url)
        let repo = Self.repo()
        try await writable.saveRepo(repo)

        model.testOnlySeedStore(try BoardStore.openReadOnly(at: url))
        await model.setRunTerms(repo, .mode(.plan))

        #expect(model.status.contains("Elliot"))
        #expect(!model.status.isEmpty)
        #expect(try await writable.repo(id: repo.id)?.permissionMode == .bypassPermissions)
    }

    /// Preflight carries a Forget button, so the row can go while the disclosure
    /// holding its picker is still on screen.
    @MainActor
    @Test("Setting terms on a repository that has been forgotten refuses, and writes nothing")
    func aForgottenRepositoryIsRefused() async throws {
        let (model, store, repo) = try await seeded(tools: [])
        try await store.deleteRepo(id: repo.id)

        await model.setRunTerms(repo, .mode(.plan))
        #expect(model.status.contains("no longer registered"))
        #expect(try await store.repos().isEmpty)
    }

    /// The other half of the lost-update pair. `setRunTerms` writes a whole row,
    /// so it must build that row from a fresh read rather than from the copy the
    /// view was rendering — otherwise it reverts whatever the sweep wrote while
    /// the disclosure sat open.
    @MainActor
    @Test("An edit applies to the current row, not to the one the screen was holding")
    func theEditAppliesToAFreshRead() async throws {
        let (model, store, repo) = try await seeded(tools: [])

        // The sweep lands while the screen holds `repo`, which predates it.
        try await store.saveRepoPreflight(id: repo.id, verdict: .failing)
        await model.setRunTerms(repo, .mode(.plan))

        let after = try #require(try await store.repo(id: repo.id))
        #expect(after.permissionMode == .plan)
        #expect(after.preflight == .failing, "the edit reverted Preflight's verdict")
    }

    @MainActor
    @Test("The sentence names the repository and what it now runs under")
    func theSentenceIsSpecific() async throws {
        let (model, _, repo) = try await seeded(tools: [])
        await model.setRunTerms(repo, .mode(.plan))
        #expect(model.status == "Elliot now runs under Plan only.")
    }

    // MARK: -

    static func repo() -> Repo {
        Repo(
            path: "/tmp/run-terms-\(UUID().uuidString)",
            nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot"
        )
    }

    @MainActor
    private func seeded(tools: [String]) async throws -> (AppModel, BoardStore, Repo) {
        let store = try BoardStore.inMemory()
        var repo = Self.repo()
        repo.extraAllowedTools = tools
        try await store.saveRepo(repo)
        let model = AppModel()
        model.testOnlySeedStore(store)
        return (model, store, repo)
    }
}
