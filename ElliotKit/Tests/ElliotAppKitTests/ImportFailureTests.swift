import ElliotEngine
import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// #42: a failed auto-import counted as done, so an empty board and an
/// unreachable one were the same screen.
///
/// Criterion 5 asked that the decision be tested "at whatever layer holds the
/// decision", and said that if it stayed in `AppModel` it would be untestable
/// "by construction". That was true when #42 was written and is not any more —
/// #72 moved `AppModel` into `ElliotAppKit`, a library. So the rule is covered
/// twice: as arithmetic in `ImportSessionStateTests`, and here as the behaviour
/// `AppModel` actually exposes to a view.
@Suite("Import failure is visible")
@MainActor
struct ImportFailureTests {

    private func repo(_ name: String) -> Repo {
        Repo(path: "/tmp/\(name)", nameWithOwner: "o/\(name)", displayName: name)
    }

    private func failed(_ name: String, _ message: String) -> ImportSummary {
        var s = ImportSummary(repoName: name)
        s.failure = message
        return s
    }

    private func succeeded(_ name: String) -> ImportSummary {
        var s = ImportSummary(repoName: name)
        s.created = 3
        return s
    }

    @Test("A repository nobody has failed to import reports no failure")
    func cleanByDefault() {
        let model = AppModel()
        let r = repo("alpha")
        model.testOnlySeed(repos: [r], cards: [])
        #expect(model.importFailure(repoID: r.id) == nil)
        #expect(model.importFailures.isEmpty)
    }

    @Test("A failed import is reported against its repository")
    func failureIsVisible() {
        let model = AppModel()
        let r = repo("alpha")
        model.testOnlySeed(repos: [r], cards: [])

        model.record(failed("alpha", "gh: not logged in"), for: r.id)

        #expect(model.importFailure(repoID: r.id) == "gh: not logged in")
        #expect(model.importFailures.count == 1)
        #expect(model.importFailures.first?.repo.id == r.id)
    }

    /// The half of #42 that actually bites. `status` is one shared line that the
    /// next event overwrites, so the failure has to be held somewhere else.
    ///
    /// `status` has no accessible setter and is not widened for a test, so this
    /// asserts the property that matters instead: the failure is not *derived*
    /// from the last sentence. A second repository importing successfully is
    /// exactly what overwrites `status` in production, and alpha's failure has
    /// to be untouched by it.
    @Test("The failure is held apart from the status line, so a later event cannot erase it")
    func survivesStatusOverwrite() {
        let model = AppModel()
        let a = repo("alpha"), b = repo("beta")
        model.testOnlySeed(repos: [a, b], cards: [])
        model.record(failed("alpha", "rate limited"), for: a.id)

        model.record(succeeded("beta"), for: b.id)

        #expect(model.importFailure(repoID: a.id) == "rate limited")
        #expect(model.status.contains("rate limited") == false, "not read back off the status line")
    }

    @Test("A later success clears the failure")
    func successClears() {
        let model = AppModel()
        let r = repo("alpha")
        model.testOnlySeed(repos: [r], cards: [])
        model.record(failed("alpha", "offline"), for: r.id)
        model.record(succeeded("alpha"), for: r.id)

        #expect(model.importFailure(repoID: r.id) == nil)
        #expect(model.importFailures.isEmpty)
    }

    @Test("One repository failing does not mark another as failed")
    func failuresDoNotBleed() {
        let model = AppModel()
        let a = repo("alpha"), b = repo("beta")
        model.testOnlySeed(repos: [a, b], cards: [])

        model.record(failed("beta", "boom"), for: b.id)

        #expect(model.importFailure(repoID: a.id) == nil)
        #expect(model.importFailure(repoID: b.id) == "boom")
        #expect(model.importFailures.map(\.repo.id) == [b.id])
    }

    /// With "All repositories" selected there is no single id to ask about, so
    /// the board reads `importFailures` instead — and it must name which ones.
    @Test("Every failure is listed for the all-repositories case")
    func allRepositoriesCase() {
        let model = AppModel()
        let a = repo("alpha"), b = repo("beta"), c = repo("gamma")
        model.testOnlySeed(repos: [a, b, c], cards: [])

        model.record(failed("alpha", "one"), for: a.id)
        model.record(succeeded("beta"), for: b.id)
        model.record(failed("gamma", "three"), for: c.id)

        let names = Set(model.importFailures.map(\.repo.displayName))
        #expect(names == ["alpha", "gamma"])
        #expect(model.importFailure(repoID: nil) == nil)
    }

    /// What the banner shows, decided here rather than in the view.
    @Test("Selecting one repository shows only its failure")
    func bannerScopedToSelection() {
        let model = AppModel()
        let a = repo("alpha"), b = repo("beta")
        model.testOnlySeed(repos: [a, b], cards: [])
        model.record(failed("alpha", "one"), for: a.id)
        model.record(failed("beta", "two"), for: b.id)

        model.selectedRepoID = a.id
        #expect(model.visibleImportFailures.map(\.message) == ["one"])

        model.selectedRepoID = b.id
        #expect(model.visibleImportFailures.map(\.message) == ["two"])
    }

    /// With "All repositories" chosen an empty board is the sum of all of them,
    /// so every failure has to be named.
    @Test("All repositories shows every failure")
    func bannerShowsAllWhenNothingSelected() {
        let model = AppModel()
        let a = repo("alpha"), b = repo("beta")
        model.testOnlySeed(repos: [a, b], cards: [])
        model.record(failed("alpha", "one"), for: a.id)
        model.record(failed("beta", "two"), for: b.id)

        model.selectedRepoID = nil
        #expect(Set(model.visibleImportFailures.map(\.message)) == ["one", "two"])
    }

    @Test("A healthy selection shows no banner at all")
    func noBannerWhenFine() {
        let model = AppModel()
        let a = repo("alpha"), b = repo("beta")
        model.testOnlySeed(repos: [a, b], cards: [])
        model.record(succeeded("alpha"), for: a.id)
        model.record(failed("beta", "two"), for: b.id)

        model.selectedRepoID = a.id
        #expect(model.visibleImportFailures.isEmpty, "alpha is fine; beta's problem is not alpha's")
    }

    /// A summary can carry counts *and* a failure — a write that broke partway.
    /// That is a failure: a re-run is idempotent, so trying again is safe and
    /// calling it done is not.
    @Test("A partial failure is a failure, not a success")
    func partialFailureIsFailure() {
        let model = AppModel()
        let r = repo("alpha")
        model.testOnlySeed(repos: [r], cards: [])

        var partial = ImportSummary(repoName: "alpha")
        partial.created = 2
        partial.failure = "write failed on issue 7"
        model.record(partial, for: r.id)

        #expect(model.importFailure(repoID: r.id) == "write failed on issue 7")
    }
}
