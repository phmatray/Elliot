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

        // ⛔ The assertion that would have failed before #218, and the one that
        // keeps it failing. `detail` was `actual` — the row's own path — so a
        // row rendered straight from the reconciler drew the same path twice, in
        // two faces. It does not reach the screen today only because
        // `RepoRegistryService.probe` rewrites `detail` for every `.ok` row
        // before the view sees one; nothing in this target said so, and a test,
        // a preview or an offline path would each meet the duplicate.
        #expect(
            rows[0].detail != rows[0].path,
            """
            an .ok row's detail is its own path again — the field the other nine verdicts use for a \
            sentence. `path` already carries it, and the view draws the two on consecutive lines
            """
        )
        // Stated positively too: `!= path` alone would pass on an empty string,
        // and `.ok` being the one verdict that says nothing is the alternative
        // this deliberately did not take.
        #expect(rows[0].detail == "Cloned where it belongs.")
        // ⚠️ And explicitly *not* "Up to date." — that is the probe's sentence
        // for its own, stronger `.ok`. The reconciler has not fetched, so
        // claiming it would be a statement about git from code that never ran it.
        #expect(!rows[0].detail.contains("Up to date"))
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

    // MARK: - Which rows a probe may ask git about (#189)

    /// The membership test, written out case by case rather than as
    /// `!isProbeable` over a complement: what is being pinned is that widening
    /// the guard past `.ok` admitted **one** further verdict, and a list stated
    /// positively is the only form in which that stays visible.
    ///
    /// The four in the second group are the ones the widening must not reach —
    /// each names a row with no clone to ask about, so probing one would be a
    /// `git` invocation against a path that is absent, elsewhere, or `nil`.
    @Test("Only a row with a clone on disk is probeable")
    func onlyRowsWithACloneAreProbeable() {
        #expect(RepoIssue.ok.isProbeable)
        #expect(RepoIssue.notChecked.isProbeable, "the listing failed; the clone is still on disk")

        let withoutAClone: [RepoIssue] = [
            .notCloned, .missing, .misplaced(expected: "/R/x"),
            .outOfScope(.fork), .outOfScope(.archived), .outOfScope(.otherRoot),
        ]
        #expect(withoutAClone.allSatisfy { !$0.isProbeable })
    }

    /// `.notRegistered` and `.unlisted` do have a clone, and are deliberately
    /// still out: both are verdicts GitHub *answered*, so there is nothing for a
    /// git observation to recover — and `.notRegistered` carries `Register`,
    /// which a probe's `fixes` assignment would silently take away.
    @Test("A verdict GitHub answered is not probeable, even with a clone on disk")
    func anAnsweredVerdictIsNotProbedAway() {
        #expect(!RepoIssue.notRegistered.isProbeable)
        #expect(!RepoIssue.unlisted.isProbeable)
    }

    /// The git states a probe *produces*. A probed row is never probed again in
    /// the same pass, so admitting them would only matter if `probe` were ever
    /// run over its own output — but stating it here is what makes the next case
    /// added to the enum face the question.
    @Test("A verdict a probe produced is not itself probeable")
    func gitStatesAreOutputNotInput() {
        let observed: [RepoIssue] = [
            .behind(by: 3), .dirty, .ahead, .diverged, .detached, .noRemote, .unreadable("no HEAD"),
        ]
        #expect(observed.allSatisfy { !$0.isProbeable })
    }

    // MARK: - How the two verdicts compose (#189)

    /// Today's behaviour for `.ok`, restated as the function rather than as the
    /// assignment it used to be. It is the control for everything below: if this
    /// stopped holding, the widening would have changed the case it was not
    /// about.
    @Test("A row the reconciler called ok takes whatever git saw")
    func okTakesTheObservation() {
        #expect(RepoIssue.ok.refined(by: .dirty) == .dirty)
        #expect(RepoIssue.ok.refined(by: .behind(by: 2)) == .behind(by: 2))
        #expect(RepoIssue.ok.refined(by: .ok) == .ok)
        #expect(RepoIssue.ok.refined(by: .outOfScope(.otherRoot)) == .outOfScope(.otherRoot))
    }

    /// The recovery this issue is for: every one of these is a fact `git`
    /// established on the local disk, and not one of them needed the listing
    /// that failed.
    @Test("An actionable git state wins over a listing that never arrived")
    func anObservationBeatsNotChecked() {
        #expect(RepoIssue.notChecked.refined(by: .dirty) == .dirty)
        #expect(RepoIssue.notChecked.refined(by: .detached) == .detached)
        #expect(RepoIssue.notChecked.refined(by: .diverged) == .diverged)
        #expect(RepoIssue.notChecked.refined(by: .ahead) == .ahead)
        #expect(RepoIssue.notChecked.refined(by: .noRemote) == .noRemote)
        #expect(RepoIssue.notChecked.refined(by: .behind(by: 4)) == .behind(by: 4))
        #expect(RepoIssue.notChecked.refined(by: .outOfScope(.otherRoot)) == .outOfScope(.otherRoot))
    }

    /// A `fetch` failing during an outage is the *likely* case, not an exotic
    /// one — and `.unreadable("fetch failed")` is more informative than
    /// `.notChecked`, because it is something that was observed rather than
    /// something that was not asked.
    @Test("An unreadable clone is an observation, and says what could not be read")
    func unreadableIsAnObservation() {
        #expect(RepoIssue.notChecked.refined(by: .unreadable("fetch failed")) == .unreadable("fetch failed"))
    }

    /// ⛔ The load-bearing one. Clean, attached and up to date is not a verdict
    /// about a repository whose remote was never reached; collapsing this pair
    /// to `.ok` is #148's defect restored, one layer down.
    @Test("A clean clone whose owner was never listed is still not checked")
    func cleanDoesNotBecomeOk() {
        #expect(RepoIssue.notChecked.refined(by: .ok) == .notChecked)
        #expect(RepoIssue.notChecked.refined(by: .ok) != .ok)
    }

    /// A row that is not probeable never asked git anything, so there is no
    /// observation to weigh.
    ///
    /// "Not probeable" is not the same as "no clone", and the list below mixes
    /// both reasons deliberately: `.notCloned`, `.missing` and `.misplaced` have
    /// nothing at the path to ask, while `.unlisted` and `.notRegistered` have a
    /// real clone and are excluded because GitHub *answered* about them (see
    /// `anAnsweredVerdictIsNotProbedAway`). Collapsing the two reasons into "no
    /// clone" is what makes dropping `.notRegistered`'s `Register` button look
    /// harmless.
    @Test("A row that is not probeable keeps its verdict whatever it is handed")
    func unprobeableRowsAreUntouched() {
        let unprobeable: [RepoIssue] = [
            .notCloned, .missing, .misplaced(expected: "/R/x"), .unlisted, .notRegistered,
            .outOfScope(.fork), .outOfScope(.archived), .outOfScope(.otherRoot),
        ]
        for issue in unprobeable {
            #expect(issue.refined(by: .dirty) == issue)
            #expect(issue.refined(by: .ok) == issue)
        }
    }
}
