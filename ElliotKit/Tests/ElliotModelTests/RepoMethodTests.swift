import Foundation
import Testing

@testable import ElliotModel

/// The accessor is one fold, in one place, mirroring `preflightVerdict`.
@Suite("A repository's method field")
struct RepoMethodTests {
    private func repository() -> Repo {
        Repo(
            path: "/tmp/repo-\(UUID().uuidString)",
            nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot"
        )
    }

    @Test("A new registration has chosen nothing, and that resolves to the default")
    func aNewRegistrationHasChosenNothing() {
        let repo = repository()
        #expect(repo.methodID == nil, "a new registration has chosen nothing")
        // ⚠️ Asserted as a **value**, not as `== MethodCatalog.resolve(nil)`.
        // That comparison is tautological: it holds for any `resolve`, including
        // one that always answered `.unknown("")`, so it can only fail if the
        // accessor passes a *different argument* — which is not what is at stake.
        guard case .unset(let pack) = repo.method else {
            Issue.record("a repository that never chose resolved to \(repo.method)")
            return
        }
        #expect(pack.id == MethodCatalog.defaultPackID)
    }

    @Test("An id the catalogue does not know is named, not substituted")
    func unknownIsNamed() {
        var repo = repository()
        repo.methodID = "not-a-method"
        #expect(repo.method == .unknown("not-a-method"))
    }

    @Test("A chosen id resolves to that pack")
    func chosenResolves() throws {
        let other = try #require(
            MethodCatalog.builtIn.first { $0.id != MethodCatalog.defaultPackID },
            "this test needs a second built-in pack; the catalogue ships four")
        var repo = repository()
        repo.methodID = other.id
        #expect(repo.method == .chosen(other))
    }
}
