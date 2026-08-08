import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import TestSupport
import Testing

@testable import ElliotEngine

/// A real `/usr/bin/git`, because what is under test is the *order* in which the
/// classifier believes git's answers. `gh` stays a stub — no network, no token.
private func syncTestConfig() -> ToolConfig {
    ToolConfig(
        claudePath: "/usr/bin/true", ghPath: "/usr/bin/true", gitPath: "/usr/bin/git",
        environment: [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
        ]
    )
}

@Suite("Repo probe", .serialized)
struct RepoRegistryServiceSyncTests {

    @Test("A dirty clone that is also behind reads dirty — the ordering is the safety property")
    func dirtyBeatsBehind() async throws {
        let (origin, clone, root) = try await makeClonePair()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try await git(["commit", "--allow-empty", "-m", "b"], in: origin)
        FileManager.default.createFile(atPath: clone + "/scratch.txt", contents: Data("x".utf8))

        let service = RepoRegistryService(store: try BoardStore.inMemory(), config: syncTestConfig())
        let probed = await service.probe([RepoRow(id: "o/r", path: clone, issue: .ok)])
        #expect(probed[0].issue == .dirty)
        #expect(probed[0].fixes.isEmpty, "a dirty clone is never offered a pull")
    }

    @Test("A clean clone that is strictly behind is offered a pull")
    func behindIsPullable() async throws {
        let (origin, clone, root) = try await makeClonePair()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try await git(["commit", "--allow-empty", "-m", "b"], in: origin)

        let service = RepoRegistryService(store: try BoardStore.inMemory(), config: syncTestConfig())
        let probed = await service.probe([RepoRow(id: "o/r", path: clone, issue: .ok)])
        #expect(probed[0].issue == .behind(by: 1))
        #expect(probed[0].fixes == [.pull(path: clone)])
        #expect(probed[0].fixes[0].label == "Pull")
    }

    @Test("A clone with local commits is left alone, not offered anything")
    func aheadIsNeverSwept() async throws {
        let (_, clone, root) = try await makeClonePair()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try await git(["commit", "--allow-empty", "-m", "mine"], in: clone)

        let service = RepoRegistryService(store: try BoardStore.inMemory(), config: syncTestConfig())
        let probed = await service.probe([RepoRow(id: "o/r", path: clone, issue: .ok)])
        #expect(probed[0].issue == .ahead)
        #expect(probed[0].fixes.isEmpty)
    }

    @Test("A detached HEAD is reported before anything else is asked")
    func detachedWins() async throws {
        let (origin, clone, root) = try await makeClonePair()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try await git(["commit", "--allow-empty", "-m", "b"], in: origin)
        try await git(["checkout", "--detach"], in: clone)

        let service = RepoRegistryService(store: try BoardStore.inMemory(), config: syncTestConfig())
        let probed = await service.probe([RepoRow(id: "o/r", path: clone, issue: .ok)])
        #expect(probed[0].issue == .detached)
        #expect(probed[0].fixes.isEmpty)
    }

    @Test("A linked worktree is out of scope, never swept")
    func linkedWorktreeIsOutOfScope() async throws {
        let (_, clone, root) = try await makeClonePair()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let linked = root + "/linked"
        try await git(["worktree", "add", "-b", "side", linked], in: clone)

        let service = RepoRegistryService(store: try BoardStore.inMemory(), config: syncTestConfig())
        let probed = await service.probe([RepoRow(id: "o/r", path: linked, issue: .ok)])
        #expect(probed[0].issue == .outOfScope(.otherRoot))
        #expect(probed[0].fixes.isEmpty)
    }

    @Test("Probing leaves a row that is not probeable exactly as it was")
    func onlyRefinesOk() async throws {
        let service = RepoRegistryService(store: try BoardStore.inMemory(), config: syncTestConfig())
        let row = RepoRow(
            id: "o/r", issue: .notCloned,
            fixes: [.clone(nameWithOwner: "o/r", into: "/tmp/x")])
        #expect(await service.probe([row]) == [row])
    }

    // MARK: - The clone GitHub could not be asked about (#189)

    /// Criterion 1, and the recovery the whole issue is for: `git` saw the dirt
    /// on the local disk, and the listing that failed was never involved in
    /// seeing it.
    @Test("A not-checked row over a dirty clone reports the dirt")
    func notCheckedIsProbedForDirt() async throws {
        let (_, clone, root) = try await makeClonePair()
        defer { try? FileManager.default.removeItem(atPath: root) }
        FileManager.default.createFile(atPath: clone + "/scratch.txt", contents: Data("x".utf8))

        let service = RepoRegistryService(store: try BoardStore.inMemory(), config: syncTestConfig())
        let probed = await service.probe([
            RepoRow(
                id: "o/r", path: clone, issue: .notChecked,
                detail: "On disk; the listing for o failed: no network.")
        ])
        #expect(probed[0].issue == .dirty)
        #expect(probed[0].fixes.isEmpty, "a dirty clone is never offered a pull")
        // Criterion 2: the git state refines the row, it does not erase the fact
        // that GitHub was never asked. `explain` reads a path and a verdict — it
        // cannot know *which* owner's listing failed, so the row's own sentence
        // is the only record of it and must survive.
        #expect(
            probed[0].detail.contains("no network"),
            "the row stopped saying why nothing is known about the repository")
        #expect(probed[0].detail.contains("Uncommitted"), "and it stopped saying what git saw")
    }

    /// ⛔ The load-bearing one, end to end. Clean, attached and up to date is a
    /// claim about a *clone*; the row's open question is about the *repository*,
    /// and nothing answered it. Rendering this as `.ok` is #148's defect
    /// restored one layer down.
    @Test("A not-checked row over a clean, up-to-date clone is still not checked")
    func cleanCloneStaysNotChecked() async throws {
        let (_, clone, root) = try await makeClonePair()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let service = RepoRegistryService(store: try BoardStore.inMemory(), config: syncTestConfig())
        let probed = await service.probe([
            RepoRow(
                id: "o/r", path: clone, issue: .notChecked,
                detail: "On disk; the listing for o failed: no network.")
        ])
        #expect(probed[0].issue == .notChecked)
        #expect(probed[0].issue != .ok)
        #expect(probed[0].fixes.isEmpty)
        #expect(
            probed[0].detail.contains("no network"),
            "a row whose verdict survived kept none of the sentence explaining it")
        // …and it still says what git found, or a probed row would be
        // indistinguishable from one the probe never touched — which during an
        // outage is the majority of rows.
        #expect(
            probed[0].detail.contains("Up to date"),
            "the clone was examined and the row says nothing about it")
    }

    /// The arm `refined(by:)`'s own comment flags as the awkward one, pinned so
    /// that reversing it is a decision rather than a drift.
    ///
    /// Every other test here uses a local `origin`, where `fetch` always
    /// succeeds — so without this one the *modal* outage is untested: no network
    /// fails the listing and the fetch alike, and `.unreadable("fetch failed")`
    /// then wins over `.notChecked` on every row. #189's spec chose that ("an
    /// observation, not a guess"); the cost is that one global failure is
    /// restated per clone and the `not checked` verdict is unreachable exactly
    /// when it applies.
    ///
    /// The unreachable remote is a path that does not exist, so no network is
    /// touched and the test stays deterministic and offline.
    @Test("A not-checked row whose remote cannot be reached reads unreadable, not not-checked")
    func notCheckedOverAnUnreachableRemoteIsUnreadable() async throws {
        let (origin, clone, root) = try await makeClonePair()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.removeItem(atPath: origin)

        let service = RepoRegistryService(store: try BoardStore.inMemory(), config: syncTestConfig())
        let probed = await service.probe([
            RepoRow(
                id: "o/r", path: clone, issue: .notChecked,
                detail: "On disk; the listing for o failed: no network.")
        ])
        #expect(probed[0].issue == .unreadable("fetch failed"))
        #expect(probed[0].issue != .notChecked)
        #expect(probed[0].fixes.isEmpty)
        #expect(probed[0].detail.contains("no network"), "the outage sentence still survives")
    }

    /// The second half of criterion 3: `.pull` is offered here on exactly the
    /// terms it is offered to an `.ok` row, and no special case was needed to
    /// get that. `--ff-only` against an already-configured upstream is a git
    /// operation — it does not touch the `gh` that just failed.
    @Test("A not-checked row that git finds strictly behind is offered the same pull an ok row is")
    func notCheckedBehindIsPullable() async throws {
        let (origin, clone, root) = try await makeClonePair()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try await git(["commit", "--allow-empty", "-m", "b"], in: origin)

        let service = RepoRegistryService(store: try BoardStore.inMemory(), config: syncTestConfig())
        let probed = await service.probe([
            RepoRow(id: "o/r", path: clone, issue: .notChecked, detail: "listing failed")
        ])
        #expect(probed[0].issue == .behind(by: 1))
        #expect(probed[0].fixes == [.pull(path: clone)])
    }

    /// Criterion 3's first half, and criterion 6's third clause. `Register` asks
    /// `gh repo view` for the default branch and falls back to a guessed
    /// `"main"` — during the outage that produced this row it would bake that
    /// guess into the store.
    ///
    /// Asserted over every state a `.notChecked` row can leave the probe in
    /// rather than over one, because "no `Register`" is a claim about the whole
    /// branch and a single clean clone would only exercise the arm where the
    /// verdict survives.
    @Test("No probed not-checked row is ever offered Register")
    func notCheckedIsNeverOfferedRegister() async throws {
        // Each `defer` is installed on the line after its own pair, not once at
        // the end: a throw from the second or third `makeClonePair()` would
        // otherwise leak the trees the earlier ones had already written.
        let (_, dirty, dirtyRoot) = try await makeClonePair()
        defer { try? FileManager.default.removeItem(atPath: dirtyRoot) }
        let (behindOrigin, behind, behindRoot) = try await makeClonePair()
        defer { try? FileManager.default.removeItem(atPath: behindRoot) }
        let (_, detached, detachedRoot) = try await makeClonePair()
        defer { try? FileManager.default.removeItem(atPath: detachedRoot) }
        FileManager.default.createFile(atPath: dirty + "/scratch.txt", contents: Data("x".utf8))
        try await git(["commit", "--allow-empty", "-m", "b"], in: behindOrigin)
        try await git(["checkout", "--detach"], in: detached)

        let service = RepoRegistryService(store: try BoardStore.inMemory(), config: syncTestConfig())
        let probed = await service.probe(
            [dirty, behind, detached].enumerated().map { index, path in
                RepoRow(id: "o/r\(index)", path: path, issue: .notChecked, detail: "listing failed")
            })

        #expect(probed.count == 3)
        for row in probed {
            #expect(
                !row.fixes.contains { if case .register = $0 { return true } else { return false } },
                "\(row.id) was offered a button grounded in the listing that failed")
        }
    }

    /// Criterion 4, stated where it can regress: the widening admitted one
    /// verdict, and these five each have either no clone to ask about or an
    /// answer GitHub already gave. `.notRegistered` is the sharpest — it has a
    /// real clone *and* a `Register` that `refine`'s `fixes` assignment would
    /// take away, so probing it would be a silent loss of the one button that
    /// row exists to offer.
    @Test("The widening admits one verdict and no others")
    func theGuardDidNotOpenTooWide() async throws {
        let (_, clone, root) = try await makeClonePair()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let service = RepoRegistryService(store: try BoardStore.inMemory(), config: syncTestConfig())
        let untouched = [
            RepoRow(
                id: "o/unregistered", path: clone, issue: .notRegistered,
                detail: "Cloned in the right place; Elliot does not know it yet.",
                fixes: [.register(path: clone)]),
            RepoRow(id: "o/unlisted", path: clone, issue: .unlisted, detail: "GitHub did not list it."),
            RepoRow(id: "o/missing", path: clone, issue: .missing, detail: "nothing is there"),
            RepoRow(
                id: "o/misplaced", path: clone, issue: .misplaced(expected: "/R/x"),
                fixes: [.move(from: clone, to: "/R/x")]),
            RepoRow(id: "o/fork", path: clone, issue: .outOfScope(.fork), detail: "A fork."),
        ]
        #expect(await service.probe(untouched) == untouched)
    }

    /// Criterion 5. Already tested for `.ok`; re-stated with `.notChecked` rows
    /// in the mix, because the widening is what changes how many rows do real
    /// work and so which ones finish out of order.
    @Test("Order survives a mixture of probeable and unprobeable rows")
    func orderSurvivesTheWidening() async throws {
        let (_, clone, root) = try await makeClonePair()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let service = RepoRegistryService(store: try BoardStore.inMemory(), config: syncTestConfig())
        let rows = (0..<20).map { index -> RepoRow in
            switch index % 3 {
            case 0: RepoRow(id: "o/ok-\(index)", path: clone, issue: .ok)
            case 1: RepoRow(id: "o/unchecked-\(index)", path: clone, issue: .notChecked)
            default: RepoRow(id: "o/gone-\(index)", issue: .notCloned)
            }
        }
        #expect(await service.probe(rows).map(\.id) == rows.map(\.id))
    }

    @Test("syncAll attempts only the behind rows, and names every skip with a reason")
    func syncOnlyPullsBehind() async throws {
        // Paths that deliberately do not exist: what is asserted here is which
        // rows were *chosen*, and a chosen row whose pull fails still has to be
        // named rather than counted as done.
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString)").path
        let service = RepoRegistryService(store: try BoardStore.inMemory(), config: syncTestConfig())
        let rows = [
            RepoRow(
                id: "o/behind", path: absent + "/behind", issue: .behind(by: 2),
                fixes: [.pull(path: absent + "/behind")]),
            RepoRow(
                id: "o/dirty", path: absent + "/dirty", issue: .dirty,
                detail: "Uncommitted changes."),
            RepoRow(
                id: "o/gone", issue: .notCloned,
                fixes: [.clone(nameWithOwner: "o/gone", into: absent + "/gone")]),
            RepoRow(id: "o/fine", path: absent + "/fine", issue: .ok),
        ]
        let summary = await service.syncAll(rows: rows)

        #expect(summary.attempted == 1, "only .behind is swept")
        #expect(summary.skipped.map(\.0).sorted() == ["o/dirty", "o/fine", "o/gone"])
        #expect(summary.skipped.allSatisfy { !$0.1.isEmpty }, "every skip carries its reason")
        #expect(summary.failed.map(\.0) == ["o/behind"], "the path does not exist, so the pull fails")
        #expect(summary.succeeded == 0)
    }

    @Test("A behind clone really is fast-forwarded, and the summary says so")
    func syncFastForwardsForReal() async throws {
        let (origin, clone, root) = try await makeClonePair()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try await git(["commit", "--allow-empty", "-m", "b"], in: origin)

        let service = RepoRegistryService(store: try BoardStore.inMemory(), config: syncTestConfig())
        let probed = await service.probe([RepoRow(id: "o/r", path: clone, issue: .ok)])
        let summary = await service.syncAll(rows: probed)

        #expect(summary.attempted == 1)
        #expect(summary.succeeded == 1)
        #expect(summary.failed.isEmpty)
        #expect(summary.skipped.isEmpty)
        // Re-probed from scratch, so the claim is git's rather than the sweep's.
        #expect(await service.probe([RepoRow(id: "o/r", path: clone, issue: .ok)])[0].issue == .ok)
    }

    @Test("Only .behind is behind — the definition the button and the sweep share")
    func onlyBehindIsBehind() {
        #expect(RepoIssue.behind(by: 1).isBehind)
        #expect(RepoIssue.behind(by: 99).isBehind)
        let others: [RepoIssue] = [
            .ok, .dirty, .ahead, .diverged, .detached, .noRemote, .unreadable("x"),
            .notCloned, .notRegistered, .missing, .misplaced(expected: "/x"),
            .outOfScope(.fork), .outOfScope(.archived), .outOfScope(.otherRoot),
        ]
        #expect(others.allSatisfy { !$0.isBehind })
    }

    @Test("The summary's sentence mentions failures only when there are some")
    func sentenceHidesAZeroItDoesNotHave() {
        let clean = SyncSummary(
            attempted: 3, succeeded: 3, skipped: [("o/a", "Up to date.")], failed: [])
        #expect(clean.sentence == "3 pulled · 1 skipped")

        let broken = SyncSummary(
            attempted: 2, succeeded: 1, skipped: [], failed: [("o/b", "refused")])
        #expect(broken.sentence == "1 pulled · 0 skipped · 1 failed")
    }

    @Test("A sweep of nothing is a summary of zeroes, not a crash")
    func emptySweep() async throws {
        let service = RepoRegistryService(store: try BoardStore.inMemory(), config: syncTestConfig())
        let summary = await service.syncAll(rows: [])
        #expect(summary.attempted == 0 && summary.succeeded == 0)
        #expect(summary.skipped.isEmpty && summary.failed.isEmpty)
    }

    @Test("A behind row with no path on it is skipped by name, never silently dropped")
    func behindWithoutAPathIsNamed() async throws {
        // Not reachable through `probe`, which only refines rows that have a
        // path — but `syncAll` takes whatever the page holds, and the one thing
        // it may never do is drop a row without saying so.
        let service = RepoRegistryService(store: try BoardStore.inMemory(), config: syncTestConfig())
        let summary = await service.syncAll(rows: [RepoRow(id: "o/pathless", issue: .behind(by: 1))])
        #expect(summary.attempted == 0)
        #expect(summary.skipped.map(\.0) == ["o/pathless"])
        #expect(summary.skipped[0].1.isEmpty == false)
    }

    @Test("Probing keeps the rows in the order it was given, whatever finishes first")
    func orderIsPreserved() async throws {
        // The page renders rows in place; a probe that returned them in
        // completion order would make every refresh jump under the cursor.
        let (_, clone, root) = try await makeClonePair()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let service = RepoRegistryService(store: try BoardStore.inMemory(), config: syncTestConfig())
        let rows = (0..<20).map { index in
            index % 2 == 0
                ? RepoRow(id: "o/clone-\(index)", path: clone, issue: .ok)
                : RepoRow(id: "o/gone-\(index)", issue: .notCloned)
        }
        let probed = await service.probe(rows)
        #expect(probed.map(\.id) == rows.map(\.id))
    }
}
