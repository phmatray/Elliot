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

@Suite("Repo reconciler")
struct RepoReconcilerTests {

    @Test("A repo on GitHub with no clone is offered a clone into its expected path")
    func notCloned() {
        let rows = RepoReconciler.rows(github: [gh("phmatray/Koine")], disk: [], registered: [], layout: layout)
        #expect(rows.count == 1)
        #expect(rows[0].issue == .notCloned)
        #expect(rows[0].fixes == [.clone(nameWithOwner: "phmatray/Koine", into: "/R/phmatray/private/Koine")])
    }

    @Test("A clone under the wrong visibility is misplaced, and the fix names the destination")
    func misplaced() {
        let rows = RepoReconciler.rows(
            github: [gh("phmatray/Koine", "PRIVATE")], disk: [slot("/R/phmatray/public/Koine")],
            registered: [registered("/R/phmatray/public/Koine", "phmatray/Koine")], layout: layout)
        #expect(rows[0].issue == .misplaced(expected: "/R/phmatray/private/Koine"))
        #expect(rows[0].fixes == [.move(from: "/R/phmatray/public/Koine", to: "/R/phmatray/private/Koine")])
        #expect(rows[0].fixes[0].label == "Move to Koine")
    }

    @Test("A clone Elliot does not know about is offered registration")
    func notRegistered() {
        let rows = RepoReconciler.rows(
            github: [gh("phmatray/Koine")],
            disk: [slot("/R/phmatray/private/Koine")],
            registered: [], layout: layout)
        #expect(rows[0].issue == .notRegistered)
        #expect(rows[0].fixes == [.register(path: "/R/phmatray/private/Koine")])
    }

    @Test("A registered path that is gone is offered forgetting, never cloning over it")
    func missing() {
        let repo = registered("/R/phmatray/private/Koine", "phmatray/Koine")
        let rows = RepoReconciler.rows(github: [gh("phmatray/Koine")], disk: [], registered: [repo], layout: layout)
        #expect(rows[0].issue == .missing)
        #expect(rows[0].fixes == [.forget(repoID: repo.id)])
    }

    @Test("Registered, present and in the right place is ok with no fix")
    func ok() {
        let rows = RepoReconciler.rows(
            github: [gh("phmatray/Koine")], disk: [slot("/R/phmatray/private/Koine")],
            registered: [registered("/R/phmatray/private/Koine", "phmatray/Koine")], layout: layout)
        #expect(rows[0].issue == .ok)
        #expect(rows[0].fixes.isEmpty)
    }

    /// The distinction this suite exists to hold: "nothing is wrong here" and "I
    /// could not check" are different answers, and only one of them is `.ok`.
    /// The detail string is unchanged — it was never the problem; the verdict it
    /// rode on was.
    @Test("A registered clone GitHub did not list is unlisted, never ok")
    func unlisted() {
        let repo = registered("/R/phmatray/private/Koine", "phmatray/Koine")
        let rows = RepoReconciler.rows(
            github: [], disk: [slot("/R/phmatray/private/Koine")],
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
    @Test("An unregistered clone GitHub did not list is still offered registration")
    func unlistedAndUnregistered() {
        let rows = RepoReconciler.rows(
            github: [], disk: [slot("/R/phmatray/private/Koine")],
            registered: [], layout: layout)
        #expect(rows[0].issue == .notRegistered)
        #expect(rows[0].fixes == [.register(path: "/R/phmatray/private/Koine")])
    }

    @Test("Forks and archived repos are listed with a reason but carry no fix")
    func outOfScopeFromGitHub() {
        let rows = RepoReconciler.rows(
            github: [gh("phmatray/castle-core", fork: true), gh("phmatray/cve-azure", archived: true)],
            disk: [], registered: [], layout: layout)
        #expect(rows.map(\.issue) == [.outOfScope(.fork), .outOfScope(.archived)])
        #expect(rows.allSatisfy { $0.fixes.isEmpty && !$0.detail.isEmpty })
    }

    @Test("A registered repo outside the tree is out of scope, and is never offered a move")
    func outOfScopeFromDisk() {
        let rows = RepoReconciler.rows(
            github: [], disk: [],
            registered: [registered("/R/_worktrees/Elliot", "phmatray/Elliot")],
            layout: layout)
        #expect(rows[0].issue == .outOfScope(.otherRoot))
        #expect(rows[0].fixes.isEmpty)
    }

    @Test("Rows are one per repository and sorted by name with owner")
    func shape() {
        let rows = RepoReconciler.rows(
            github: [gh("phmatray/zeta"), gh("Atypical-Consulting/alpha")],
            disk: [], registered: [], layout: layout)
        #expect(rows.map(\.id) == ["Atypical-Consulting/alpha", "phmatray/zeta"])
    }
}
