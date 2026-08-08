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
private func arrived(_ repos: [GHRepoSummary] = []) -> GitHubListing {
    GitHubListing(repos: repos)
}

/// What a row can do about the board, asserted against rows the **reconciler**
/// produced rather than rows written by hand here.
///
/// The distinction is the whole point of the suite: `boardAction` reads
/// `repoID` and `fixes`, and both are set by `RepoReconciler.row(for:…)` in
/// combinations a hand-built fixture would only guess at. A test that
/// constructed `RepoRow(repoID: nil, fixes: [.register(…)])` itself would
/// assert my model of the reconciler, not the reconciler.
@Suite("Repo row board action")
struct RepoRowBoardActionTests {

    // MARK: - Registered rows go to the board, whatever else is wrong with them

    @Test("A registered, present, correctly-placed row opens the board")
    func okOpens() {
        let repo = registered("/R/phmatray/private/Koine", "phmatray/Koine")
        let rows = RepoReconciler.rows(
            listing: arrived([gh("phmatray/Koine")]), disk: [slot("/R/phmatray/private/Koine")],
            registered: [repo], layout: layout)
        #expect(rows[0].issue == .ok)
        #expect(rows[0].boardAction == .open(repoID: repo.id))
    }

    /// Registration, not `.ok`, is the gate — and this is the case that proves
    /// it is not a restatement of "the row is fine". Nothing is on disk, so the
    /// row's own fix is `Forget`; its cards are still on the board, and a person
    /// looking at a `missing` row is exactly the person who wants to see them.
    @Test("A registered row with nothing on disk still opens the board")
    func missingOpens() {
        let repo = registered("/R/phmatray/private/Koine", "phmatray/Koine")
        let rows = RepoReconciler.rows(
            listing: arrived([gh("phmatray/Koine")]), disk: [], registered: [repo], layout: layout)
        #expect(rows[0].issue == .missing)
        #expect(rows[0].boardAction == .open(repoID: repo.id))
    }

    /// The same claim from the other direction: GitHub answered and did not
    /// mention this repository, which says nothing about its cards.
    @Test("A registered row GitHub did not list still opens the board")
    func unlistedOpens() {
        let repo = registered("/R/phmatray/private/Koine", "phmatray/Koine")
        let rows = RepoReconciler.rows(
            listing: arrived(), disk: [slot("/R/phmatray/private/Koine")],
            registered: [repo], layout: layout)
        #expect(rows[0].issue == .unlisted)
        #expect(rows[0].boardAction == .open(repoID: repo.id))
    }

    // MARK: - Unregistered rows do not

    /// Criterion 3. `.registerFirst` is read from the row's own `fixes`, so what
    /// is asserted here is that the row offering `Register` is the same row that
    /// declines to offer `Open board` — not two independent guesses at when a
    /// registration exists.
    @Test("A clone Elliot does not know yet asks to be registered first")
    func notRegisteredAsksToRegister() {
        let rows = RepoReconciler.rows(
            listing: arrived([gh("phmatray/Koine")]), disk: [slot("/R/phmatray/private/Koine")],
            registered: [], layout: layout)
        #expect(rows[0].issue == .notRegistered)
        #expect(rows[0].fixes == [.register(path: "/R/phmatray/private/Koine")])
        #expect(rows[0].boardAction == .registerFirst)
    }

    @Test("A repository with no clone has nothing to open and nothing to register")
    func notClonedIsUnavailable() {
        let rows = RepoReconciler.rows(
            listing: arrived([gh("phmatray/Koine")]), disk: [], registered: [], layout: layout)
        #expect(rows[0].issue == .notCloned)
        #expect(rows[0].boardAction == .unavailable)
    }

    /// A fork carries `Clone` at most and never `Register`, so the third case is
    /// reachable and is not a synonym for `.registerFirst`.
    @Test("An unregistered fork is unavailable, not register-first")
    func unregisteredForkIsUnavailable() {
        let rows = RepoReconciler.rows(
            listing: arrived([gh("phmatray/castle-core", fork: true)]),
            disk: [], registered: [], layout: layout)
        #expect(rows[0].issue == .outOfScope(.fork))
        #expect(rows[0].boardAction == .unavailable)
    }

    // MARK: - The invariant criterion 3 actually rests on

    /// Over every row a mixed fixture produces: no row both opens the board and
    /// offers `Register`.
    ///
    /// Stated as a sweep rather than as six more single-row assertions because
    /// the failure it guards against is a *new* branch in `RepoReconciler.row`
    /// that sets `repoID` while still handing out a `Register` — a row nobody
    /// wrote a case for here, which is exactly the row a case-by-case suite
    /// cannot see.
    @Test("No row ever offers Open board and Register at the same time")
    func openAndRegisterAreExclusive() {
        let koine = registered("/R/phmatray/private/Koine", "phmatray/Koine")
        let stray = registered("/R/_worktrees/Elliot", "phmatray/Elliot")
        let rows = RepoReconciler.rows(
            listing: GitHubListing(
                repos: [
                    gh("phmatray/Koine"),                              // registered, ok
                    gh("phmatray/Ducky"),                              // on disk, unregistered
                    gh("phmatray/Filament"),                           // no clone at all
                    gh("phmatray/castle-core", fork: true),            // out of scope
                    gh("Atypical-Consulting/alpha", "PUBLIC"),         // misplaced below
                ],
                failures: [OwnerListingFailure(owner: "nobody", reason: "gh exited 1: no network")]),
            disk: [
                slot("/R/phmatray/private/Koine"), slot("/R/phmatray/private/Ducky"),
                slot("/R/Atypical-Consulting/private/alpha"), slot("/R/phmatray/private/Orphan"),
            ],
            registered: [koine, stray], layout: layout)

        // The fixture has to actually contain both kinds, or the sweep below
        // passes by describing an empty set.
        #expect(rows.contains { $0.boardAction == .open(repoID: koine.id) })
        #expect(rows.contains { $0.boardAction == .registerFirst })

        for row in rows {
            let offersRegister = row.fixes.contains {
                if case .register = $0 { return true } else { return false }
            }
            if case .open = row.boardAction {
                #expect(!offersRegister, "\(row.id) offers Open board and Register at once")
            }
        }
    }
}
