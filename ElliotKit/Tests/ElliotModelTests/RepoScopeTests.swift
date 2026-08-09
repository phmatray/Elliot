import Foundation
import Testing

@testable import ElliotModel

@Suite("Out-of-scope is decided once")
struct RepoScopeTests {

    private func summary(
        fork: Bool = false, archived: Bool = false, empty: Bool = false
    ) -> GHRepoSummary {
        GHRepoSummary(
            nameWithOwner: "phmatray/Foo", visibility: "PUBLIC",
            isFork: fork, isArchived: archived, isEmpty: empty)
    }

    @Test("An ordinary repository is in scope")
    func ordinaryIsInScope() {
        #expect(RepoIssue.OutOfScope.of(summary()) == nil)
    }

    /// Fork is checked first so a fork reports as a fork whatever else is true.
    /// An archived fork answering `.archived` would send it to the wrong sweep.
    @Test("A fork reports as a fork even when archived and empty")
    func forkWins() {
        #expect(RepoIssue.OutOfScope.of(summary(fork: true, archived: true, empty: true)) == .fork)
    }

    @Test("Archived beats empty")
    func archivedBeatsEmpty() {
        #expect(RepoIssue.OutOfScope.of(summary(archived: true, empty: true)) == .archived)
    }

    @Test("An empty repository is out of scope")
    func emptyIsOutOfScope() {
        #expect(RepoIssue.OutOfScope.of(summary(empty: true)) == .empty)
    }

    /// The reconciler must go through the same function, not keep its own
    /// ternary — that is the whole reason this exists.
    @Test("The reconciler agrees with the shared judgement")
    func reconcilerAgrees() {
        let rows = RepoReconciler.rows(
            listing: GitHubListing(repos: [summary(fork: true)]),
            disk: [], registered: [], layout: .portfolio)
        #expect(rows.first?.issue == .outOfScope(.fork))
    }
}
