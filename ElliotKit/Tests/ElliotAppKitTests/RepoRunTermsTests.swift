import ElliotModel
import ElliotStore
import Foundation
import Testing

@testable import ElliotAppKit

/// The writer `permissionMode` and `extraAllowedTools` never had.
///
/// Both are **v1** columns. `RunScheduler` reads them at spawn and
/// `board_list_repos` reports the mode — and until #333 nothing anywhere
/// assigned either one, so every registration took `bypassPermissions` and `[]`
/// for ever. `Repo.permissionMode`'s own doc comment said a single repository
/// could be tightened without touching the others; it could not.
///
/// ⚠️ What they turn into changed under them in Stage 1 of #379, and the two
/// parted company: `ClaudeInvocation.arguments()` used to emit a flag for each,
/// but `permissionMode` is now an ACP `session/set_config_option` and
/// `extraAllowedTools` has no ACP equivalent at all — a non-empty list is
/// refused by `AgentRun.start` rather than granted. This suite is about the
/// writer, which is why it still holds either way.
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

    // MARK: - The sweep's write, which no behavioural test can reach

    /// ⚠️ **This gate exists because breaking the fix left the suite green.**
    ///
    /// `BoardStoreTests.verdictWriteIsTargeted` proves `saveRepoPreflight`
    /// writes one column; nothing proved that `AppModel.record` *calls* it.
    /// Restoring the old `var updated = repo; updated.preflight = verdict; try
    /// await store.saveRepo(updated)` passed all 2005 tests — the whole hazard
    /// back, unremarked.
    ///
    /// It cannot be caught behaviourally from here. The window only opens while
    /// `record`'s caller is suspended inside `preflight.repoChecks(repo)`, which
    /// is a concrete `PreflightService` shelling out to `gh` and `git` with no
    /// seam to suspend on demand; a test that raced it would assert a timing
    /// this machine happened to produce. So the claim is about the *source*, and
    /// it is checked in the source — the same answer `DrainDuplicationTests` and
    /// `DefaultActionTests` give, for the same reason.
    @Test("The Preflight sweep writes the verdict alone, never the whole captured row")
    func theSweepDoesNotCarryTheRow() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ElliotAppKit/AppModel.swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        let marker = "private func record(_ results: [CheckResult], for repo: Repo) async {"
        let start = try #require(
            text.range(of: marker), "`record` has been renamed; this gate is now checking nothing"
        )
        let body = String(text[start.upperBound...].prefix(1400))
        let code = body.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
            .joined(separator: "\n")

        #expect(code.contains("store.saveRepoPreflight("))
        #expect(
            !code.contains("store.saveRepo("),
            "the sweep writes the whole row again, reverting anything saved while it ran"
        )
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
