import Foundation
import Testing

@testable import ElliotModel

private let layout = RepoTreeLayout(root: "/R", owners: ["phmatray", "Atypical-Consulting"])

private func gh(
    _ nameWithOwner: String, _ visibility: String = "PRIVATE",
    fork: Bool = false, archived: Bool = false
) -> GHRepoSummary {
    GHRepoSummary(
        nameWithOwner: nameWithOwner, visibility: visibility,
        defaultBranchRef: .init(name: "main"), isFork: fork, isArchived: archived,
        url: "https://github.com/\(nameWithOwner)")
}
private func slot(_ path: String) -> RepoSlot { layout.slot(forPath: path)! }
private func registered(_ path: String, _ nameWithOwner: String) -> Repo {
    Repo(path: path, nameWithOwner: nameWithOwner, displayName: (path as NSString).lastPathComponent)
}

/// A listing that arrived, in full. Spelled out here rather than defaulted on
/// `rows` itself: the default is exactly what would let a caller re-assert that
/// everything is fine by forgetting an argument.
private func arrived(_ repos: [GHRepoSummary] = []) -> GitHubListing {
    GitHubListing(repos: repos)
}

private func failed(_ owner: String, _ reason: String = "gh exited 1: no network") -> GitHubListing {
    GitHubListing(repos: [], failures: [OwnerListingFailure(owner: owner, reason: reason)])
}

@Suite("Repo reconciler")
struct RepoReconcilerTests {

    @Test("A repo on GitHub with no clone is offered a clone into its expected path")
    func notCloned() {
        let rows = RepoReconciler.rows(
            listing: arrived([gh("phmatray/Koine")]), disk: [], registered: [], layout: layout)
        #expect(rows.count == 1)
        #expect(rows[0].issue == .notCloned)
        #expect(rows[0].fixes == [.clone(nameWithOwner: "phmatray/Koine", into: "/R/phmatray/private/Koine")])
    }

    @Test("A clone under the wrong visibility is misplaced, and the fix names the destination")
    func misplaced() {
        let rows = RepoReconciler.rows(
            listing: arrived([gh("phmatray/Koine", "PRIVATE")]), disk: [slot("/R/phmatray/public/Koine")],
            registered: [registered("/R/phmatray/public/Koine", "phmatray/Koine")], layout: layout)
        #expect(rows[0].issue == .misplaced(expected: "/R/phmatray/private/Koine"))
        #expect(rows[0].fixes == [.move(from: "/R/phmatray/public/Koine", to: "/R/phmatray/private/Koine")])
        #expect(rows[0].fixes[0].label == "Move to Koine")
    }

    @Test("A clone Elliot does not know about is offered registration")
    func notRegistered() {
        let rows = RepoReconciler.rows(
            listing: arrived([gh("phmatray/Koine")]),
            disk: [slot("/R/phmatray/private/Koine")],
            registered: [], layout: layout)
        #expect(rows[0].issue == .notRegistered)
        #expect(rows[0].fixes == [.register(path: "/R/phmatray/private/Koine")])
    }

    @Test("A registered path that is gone is offered forgetting, never cloning over it")
    func missing() {
        let repo = registered("/R/phmatray/private/Koine", "phmatray/Koine")
        let rows = RepoReconciler.rows(
            listing: arrived([gh("phmatray/Koine")]), disk: [], registered: [repo], layout: layout)
        #expect(rows[0].issue == .missing)
        #expect(rows[0].fixes == [.forget(repoID: repo.id)])
    }

    @Test("Registered, present and in the right place is ok with no fix")
    func ok() {
        let rows = RepoReconciler.rows(
            listing: arrived([gh("phmatray/Koine")]), disk: [slot("/R/phmatray/private/Koine")],
            registered: [registered("/R/phmatray/private/Koine", "phmatray/Koine")], layout: layout)
        #expect(rows[0].issue == .ok)
        #expect(rows[0].fixes.isEmpty)
    }

    /// The distinction this suite exists to hold: "nothing is wrong here" and "I
    /// could not check" are different answers, and only one of them is `.ok`.
    /// The detail string is unchanged — it was never the problem; the verdict it
    /// rode on was.
    ///
    /// Since #148 this is also the *control* for `.notChecked`: `arrived()` is a
    /// listing that came back and mentioned nothing, which is the one input
    /// `.unlisted` is entitled to. Read it beside `notCheckedWhenTheListingFailed`
    /// — same disk, same store, different answer from GitHub.
    @Test("A registered clone GitHub did not list is unlisted, never ok")
    func unlisted() {
        let repo = registered("/R/phmatray/private/Koine", "phmatray/Koine")
        let rows = RepoReconciler.rows(
            listing: arrived(), disk: [slot("/R/phmatray/private/Koine")],
            registered: [repo], layout: layout)
        #expect(rows[0].issue == .unlisted)
        #expect(rows[0].detail == "On disk; GitHub did not list it.")
        #expect(rows[0].repoID == repo.id)
        // No fix: Elliot cannot resolve this from here. Whether the repository
        // was renamed, deleted, or simply missing from an incomplete answer is a
        // question about GitHub, and the reconciler is pure — it does not ask.
        #expect(rows[0].fixes.isEmpty)
    }

    /// The other half of the claim above: an *unregistered* clone GitHub did not
    /// list keeps `.notRegistered`, because that verdict is already actionable
    /// and carries the fix. Only the `.ok` pairing was the lie.
    ///
    /// The second control for #148, and the one that matters most: `Register` is
    /// still offered here, because GitHub *answered*. It is what the button is
    /// grounded in, and what `notCheckedCarriesNoFix` takes away when the answer
    /// never came.
    @Test("An unregistered clone GitHub did not list is still offered registration")
    func unlistedAndUnregistered() {
        let rows = RepoReconciler.rows(
            listing: arrived(), disk: [slot("/R/phmatray/private/Koine")],
            registered: [], layout: layout)
        #expect(rows[0].issue == .notRegistered)
        #expect(rows[0].fixes == [.register(path: "/R/phmatray/private/Koine")])
    }

    // MARK: - A listing that never arrived (#148)

    /// The defect, stated: with `gh` failing, the clone used to be handed
    /// `.notRegistered` **and a button**, because an empty array is what both a
    /// failure and an empty account look like once the error is thrown away.
    @Test("An unregistered clone whose owner's listing failed is not checked, and is offered nothing")
    func notCheckedCarriesNoFix() {
        let rows = RepoReconciler.rows(
            listing: failed("phmatray"), disk: [slot("/R/phmatray/private/Koine")],
            registered: [], layout: layout)
        #expect(rows[0].issue == .notChecked)
        #expect(rows[0].fixes.isEmpty, "every action here would be grounded in the listing that failed")
        #expect(rows[0].detail.contains("no network"), "the row says why nothing is known")
    }

    /// Registered changes nothing about the verdict, which is the point:
    /// `.unlisted` is a fact about the *repository* and this is a fact about the
    /// *listing*, so the store's opinion does not enter into it.
    @Test("A registered clone whose owner's listing failed is not checked, never unlisted")
    func notCheckedWhenTheListingFailed() {
        let repo = registered("/R/phmatray/private/Koine", "phmatray/Koine")
        let rows = RepoReconciler.rows(
            listing: failed("phmatray"), disk: [slot("/R/phmatray/private/Koine")],
            registered: [repo], layout: layout)
        #expect(rows[0].issue == .notChecked)
        #expect(rows[0].issue != .unlisted)
        #expect(rows[0].repoID == repo.id, "the row still knows what Elliot knows")
        #expect(rows[0].fixes.isEmpty)
    }

    /// Criterion 5, and the regression approach 4 would have shipped: one
    /// owner's rate limit must cost that owner's verdicts and nothing else.
    /// Asserted as equality against the healthy owner's rows computed on their
    /// own, so a future change that merely *reworded* the healthy row would fail
    /// here rather than passing on a weaker claim.
    @Test("One owner's failed listing leaves a healthy owner's rows exactly as they were")
    func aFailedOwnerDoesNotCostAHealthyOne() {
        let alpha = gh("Atypical-Consulting/alpha")
        let healthyDisk = slot("/R/Atypical-Consulting/private/alpha")

        let alone = RepoReconciler.rows(
            listing: arrived([alpha]), disk: [healthyDisk], registered: [], layout: layout)
        let together = RepoReconciler.rows(
            listing: GitHubListing(
                repos: [alpha],
                failures: [OwnerListingFailure(owner: "phmatray", reason: "gh exited 1: rate limited")]),
            disk: [healthyDisk, slot("/R/phmatray/private/Koine")],
            registered: [], layout: layout)

        #expect(together.filter { $0.id.hasPrefix("Atypical-Consulting/") } == alone)
        #expect(together.first { $0.id == "phmatray/Koine" }?.issue == .notChecked)
    }

    /// `.missing` is a fact about the **disk**, and the disk scan succeeded — so
    /// a failed listing must not soften it. This is the loop the change
    /// deliberately did not touch, pinned so a later tidy-up cannot widen
    /// `.notChecked` into it.
    @Test("A registered repo absent from disk is still missing, even with the listing gone")
    func missingSurvivesAFailedListing() {
        let repo = registered("/R/phmatray/private/Koine", "phmatray/Koine")
        let rows = RepoReconciler.rows(
            listing: failed("phmatray"), disk: [], registered: [repo], layout: layout)
        #expect(rows[0].issue == .missing)
        #expect(rows[0].fixes == [.forget(repoID: repo.id)])
    }

    @Test("Forks and archived repos are listed with a reason but carry no fix")
    func outOfScopeFromGitHub() {
        let rows = RepoReconciler.rows(
            listing: arrived([
                gh("phmatray/castle-core", fork: true), gh("phmatray/cve-azure", archived: true),
            ]),
            disk: [], registered: [], layout: layout)
        #expect(rows.map(\.issue) == [.outOfScope(.fork), .outOfScope(.archived)])
        #expect(rows.allSatisfy { $0.fixes.isEmpty && !$0.detail.isEmpty })
    }

    @Test("A registered repo outside the tree is out of scope, and is never offered a move")
    func outOfScopeFromDisk() {
        let rows = RepoReconciler.rows(
            listing: arrived(), disk: [],
            registered: [registered("/R/_worktrees/Elliot", "phmatray/Elliot")],
            layout: layout)
        #expect(rows[0].issue == .outOfScope(.otherRoot))
        #expect(rows[0].fixes.isEmpty)
    }

    @Test("Rows are one per repository and sorted by name with owner")
    func shape() {
        let rows = RepoReconciler.rows(
            listing: arrived([gh("phmatray/zeta"), gh("Atypical-Consulting/alpha")]),
            disk: [], registered: [], layout: layout)
        #expect(rows.map(\.id) == ["Atypical-Consulting/alpha", "phmatray/zeta"])
    }
}
