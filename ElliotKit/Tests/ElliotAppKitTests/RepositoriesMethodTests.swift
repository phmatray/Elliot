import ElliotModel
import ElliotStore
import Foundation
import TestSupport
import Testing

@testable import ElliotAppKit

/// The one control on the Repositories page that changes what a drag will
/// *execute*, and the sentences it says about the three states a method can be
/// in.
///
/// `nonisolated static` vocabulary, read here rather than rendered: what the
/// page *says* is assertable, where its row sits on screen still is not — which
/// is what the task's on-screen pass is for.
@Suite("Repositories method")
struct RepositoriesMethodTests {

    @Test("Unset, chosen and unknown do not read alike")
    func theThreeStatesAreDistinguishable() throws {
        let pack = try #require(MethodCatalog.builtIn.first)
        let unset = RepositoriesView.methodHelp(.unset(pack))
        let chosen = RepositoriesView.methodHelp(.chosen(pack))
        let unknown = RepositoriesView.methodHelp(.unknown("no-such-method"))

        // "Never chosen" and "chose this one" run the same commands today and
        // are different facts: only one of them follows the default if it moves.
        #expect(unset != chosen)
        #expect(unset.lowercased().contains("never chosen"))
        #expect(chosen.contains(pack.displayName))

        // An id this build has no pack for must be named, not hidden. A blank
        // menu reads as "no method", which is the silent substitution
        // `MethodResolution.unknown` exists to stop.
        #expect(unknown.contains("no-such-method"))
        #expect(unknown != unset)
        #expect(unknown != chosen)
    }

    @Test("The unset row names the default it resolves to, and says it is a default")
    func unsetRowNamesItsFallback() throws {
        let label = RepositoriesView.unsetMethodLabel()
        guard case .unset(let fallback) = MethodCatalog.resolve(nil) else {
            Issue.record("resolve(nil) must be .unset")
            return
        }
        #expect(label.contains(fallback.displayName))
        #expect(label.lowercased().contains("default"))
        // And it is not the same string as picking that pack on purpose, or the
        // menu would show two rows a reader cannot tell apart.
        #expect(label != fallback.displayName)
    }

    @Test("An unknown id is offered as leaveable, and does not read like a choice")
    func unknownRowIsMarked() {
        let label = RepositoriesView.unknownMethodLabel("gsd-v2")
        #expect(label.contains("gsd-v2"))
        #expect(label != "gsd-v2")
        #expect(!MethodCatalog.builtIn.map(\.displayName).contains(label))
    }

    /// M3: `MethodCatalog.resolve` trims before it looks up, so a stored
    /// `"  gsd  "` resolves `.chosen(gsd)` — but the picker's own tags are
    /// `pack.id` (never padded) and `nil`. Binding the selection to the raw
    /// `repo.methodID` would therefore match no row and the menu would render
    /// blank, reading as "no method" for a repository that plainly chose one.
    @Test("A stored id with surrounding whitespace still shows a selected row")
    func selectionSurvivesWhitespace() throws {
        let pack = try #require(MethodCatalog.builtIn.first { $0.id != MethodCatalog.defaultPackID })
        let resolution = MethodCatalog.resolve("  \(pack.id)  ")
        guard case .chosen(let resolved) = resolution else {
            Issue.record("a whitespace-padded id matching a built-in pack must resolve as .chosen")
            return
        }
        #expect(resolved.id == pack.id)

        // The value `selectedMethodID` hands the picker must equal a tag the
        // menu actually writes — here, the built-in pack's own (clean) id —
        // never the raw, whitespace-padded string nobody's row carries.
        let tag = RepositoriesView.selectedMethodID(resolution)
        #expect(tag == pack.id)
        #expect(MethodCatalog.builtIn.map(\.id).contains(tag))
    }

    // MARK: - The write

    @MainActor
    @Test("Choosing a method writes it, and choosing none clears it")
    func setRepoMethodWritesThrough() async throws {
        _ = TestHome.root
        let store = try BoardStore.inMemory()
        let repo = Repo(
            path: "/tmp/sandbox", nameWithOwner: "phmatray/sandbox", displayName: "sandbox")
        try await store.saveRepo(repo)

        let model = AppModel()
        model.testOnlySeedStore(store)
        model.testOnlySeed(repos: [repo], cards: [])

        // ⚠️ Depends on the catalogue shipping a second pack — see the task's
        // Interfaces note. A hard failure here means Task 2's contents changed.
        let pack = try #require(
            MethodCatalog.builtIn.first { $0.id != MethodCatalog.defaultPackID })
        await model.setRepoMethod(repo, methodID: pack.id)
        #expect(try await store.repos().first?.methodID == pack.id)

        // Back to unset. `nil` is a state and not a missing value, so the menu
        // must be able to return to it — a control you can leave but not come
        // back to is a one-way door on a setting that decides what runs.
        var chosen = try #require(try await store.repos().first)
        await model.setRepoMethod(chosen, methodID: nil)
        chosen = try #require(try await store.repos().first)
        #expect(chosen.methodID == nil)
        if case .unset = chosen.method {} else {
            Issue.record("a cleared methodID must resolve as .unset")
        }
    }

    @MainActor
    @Test("A write that lands on an unknown id is still stored, and still resolves as unknown")
    func unknownIdSurvivesTheRoundTrip() async throws {
        // Not reachable from the menu, but reachable from `.elliot/settings.json`
        // in wave 3 and from a pack that was removed between builds. The store
        // must not quietly normalise it: Preflight's `.fail` is what tells the
        // reader, and it can only fire on a value that survived.
        _ = TestHome.root
        let store = try BoardStore.inMemory()
        let repo = Repo(path: "/tmp/sandbox2", nameWithOwner: "phmatray/s2", displayName: "s2")
        try await store.saveRepo(repo)

        let model = AppModel()
        model.testOnlySeedStore(store)
        model.testOnlySeed(repos: [repo], cards: [])

        await model.setRepoMethod(repo, methodID: "no-such-method")
        let stored = try #require(try await store.repos().first)
        #expect(stored.methodID == "no-such-method")
        if case .unknown(let id) = stored.method {
            #expect(id == "no-such-method")
        } else {
            Issue.record("an id the catalogue does not know must resolve as .unknown")
        }
    }
}
