import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine

/// Drives `PRWatcher.tick()` against the real `Scripts/fake-gh.sh` and counts
/// what it actually asked for.
///
/// The claim under test is not "it reads the status" — that is one line. It is
/// **"it does not read the status when nothing changed"**, which is the whole
/// cost argument for reading per-card rather than enriching the listing. A cache
/// that never hits is just a slower poller, and nothing in a green build would
/// say so.
@Suite("PR watcher status")
struct PRWatcherStatusTests {

    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ElliotEngineTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // ElliotKit
        .deletingLastPathComponent()   // repo root

    private static let fakeGH = repoRoot.appendingPathComponent("Scripts/fake-gh.sh").path

    private static func ghFixture(_ name: String) -> String {
        repoRoot.appendingPathComponent("Fixtures/gh/\(name)").path
    }

    /// Never asked to move anything here — the sighting path has its own tests.
    private final class NoMover: SystemMoving, @unchecked Sendable {
        func applySystemMove(cardID: UUID, to: ElliotModel.Column, reason: MoveOrigin.SystemReason) async {}
    }

    private struct Harness {
        let store: BoardStore
        let watcher: PRWatcher
        let repo: Repo
        let argvPath: String
        let mover: NoMover

        /// How many `gh pr view` invocations reached the fake so far.
        func prViewCalls() -> Int {
            guard let text = try? String(contentsOfFile: argvPath, encoding: .utf8) else { return 0 }
            // argv is dumped one argument per line, so a `pr view` shows up as
            // the literal line "view" immediately after a line "pr".
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            return zip(lines, lines.dropFirst()).count { $0 == "pr" && $1 == "view" }
        }
    }

    /// A pull request listing carrying `headRefOid` — the scalar the skip rule
    /// compares against — written fresh so the oid can be varied per test.
    private func prsFixture(number: Int, headRefOid: String, branch: String) throws -> String {
        let json = """
            [{"number": \(number),
              "url": "https://github.com/phmatray/Elliot/pull/\(number)",
              "title": "feat(app): something",
              "body": "Closes #7",
              "headRefName": "\(branch)",
              "isDraft": false,
              "state": "OPEN",
              "createdAt": "2026-08-01T10:00:00Z",
              "mergedAt": null,
              "headRefOid": "\(headRefOid)"}]
            """
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prs-\(UUID().uuidString).json").path
        try json.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func makeHarness(
        column: ElliotModel.Column = .inReview,
        prNumber: Int? = 52,
        issueNumber: Int? = 7,
        headRefOid: String = "3be5f1ee906ff61bdedef0072b635ec6ec40c632",
        prView: String = "pr-view-unstable.json"
    ) async throws -> Harness {
        let store = try BoardStore.inMemory()
        let repo = Repo(
            path: "/tmp/repo-\(UUID().uuidString)",
            nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        try await store.saveRepo(repo)

        let now = Date()
        var card = Card(
            repoID: repo.id, title: "Something", column: column, orderIndex: 0,
            issueNumber: issueNumber, prNumber: prNumber, branch: "feat/7-something",
            columnEnteredAt: now, createdAt: now, updatedAt: now)
        card.prURL = "https://github.com/phmatray/Elliot/pull/52"
        try await store.saveCard(card)

        let argvPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("argv-\(UUID().uuidString).txt").path
        let config = ToolConfig(
            ghPath: Self.fakeGH, gitPath: "",
            environment: [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "FAKE_GH_PRS": try prsFixture(
                    number: prNumber ?? 52, headRefOid: headRefOid, branch: "feat/7-something"),
                "FAKE_GH_PR_VIEW": Self.ghFixture(prView),
                "FAKE_GH_ARGV_OUT": argvPath,
            ])
        let mover = NoMover()
        return Harness(
            store: store,
            watcher: PRWatcher(store: store, gh: GHClient(config: config), mover: mover),
            repo: repo, argvPath: argvPath, mover: mover)
    }

    // MARK: - It reads

    @Test("A card waiting in In Review gets its pull request's status stored")
    func readsAWaitingCard() async throws {
        let harness = try await makeHarness()
        await harness.watcher.tick()

        let stored = try #require(try await harness.store.prStatus(repoID: harness.repo.id, prNumber: 52))
        #expect(stored.rawMergeStateStatus == "UNSTABLE")
        #expect(stored.headRefOid == "3be5f1ee906ff61bdedef0072b635ec6ec40c632")
        #expect(harness.prViewCalls() == 1)
    }

    @Test("The stored reading resolves to the sign the card will draw")
    func storedReadingResolves() async throws {
        let harness = try await makeHarness(
            headRefOid: "898b1aee67d8d94a9c15869046e43d45dab5e1b8",
            prView: "pr-view-conflict.json")
        await harness.watcher.tick()

        let stored = try #require(try await harness.store.prStatus(repoID: harness.repo.id, prNumber: 52))
        let resolved = stored.resolved(now: Date(), currentHeadOid: stored.headRefOid)
        #expect(resolved.sign == PRSign.conflict)
    }

    // MARK: - It skips, which is the expensive claim

    @Test("A second tick over an unchanged, settled pull request spends nothing")
    func settledPullRequestIsNotReRead() async throws {
        // The unstable fixture's only check is IN_PROGRESS, which is a legitimate
        // reason to look again — so this test needs a *finished* reading. It
        // writes one directly, then proves the tick leaves it alone.
        let harness = try await makeHarness()
        try await harness.store.savePRStatus(PRStatus(
            repoID: harness.repo.id, prNumber: 52,
            headRefOid: "3be5f1ee906ff61bdedef0072b635ec6ec40c632",
            checkedAt: Date(),
            rawMergeStateStatus: "CLEAN", rawMergeable: "MERGEABLE", rawReviewDecision: "",
            checks: [GHMergeStatus.StatusCheck(name: "build", conclusion: "SUCCESS", status: "COMPLETED")]))

        await harness.watcher.tick()
        #expect(harness.prViewCalls() == 0)
    }

    @Test("A moved head is re-read, because the stored facts describe another commit")
    func movedHeadIsReRead() async throws {
        let harness = try await makeHarness()
        try await harness.store.savePRStatus(PRStatus(
            repoID: harness.repo.id, prNumber: 52,
            headRefOid: "0000000000000000000000000000000000000000",
            checkedAt: Date(),
            rawMergeStateStatus: "CLEAN", rawMergeable: "MERGEABLE", rawReviewDecision: "",
            checks: [GHMergeStatus.StatusCheck(name: "build", conclusion: "SUCCESS", status: "COMPLETED")]))

        await harness.watcher.tick()
        #expect(harness.prViewCalls() == 1)
        let stored = try #require(try await harness.store.prStatus(repoID: harness.repo.id, prNumber: 52))
        #expect(stored.headRefOid == "3be5f1ee906ff61bdedef0072b635ec6ec40c632")
    }

    @Test("A check still running is looked at again")
    func runningCheckIsReRead() async throws {
        let harness = try await makeHarness()
        await harness.watcher.tick()   // stores the IN_PROGRESS fixture
        await harness.watcher.tick()
        #expect(harness.prViewCalls() == 2)
    }

    // MARK: - It reads nothing it should not

    @Test(
        "No column other than In Review costs a call",
        arguments: [ElliotModel.Column.backlog, .todo, .inProgress, .done])
    func onlyInReviewIsRead(column: ElliotModel.Column) async throws {
        let harness = try await makeHarness(column: column)
        await harness.watcher.tick()
        #expect(harness.prViewCalls() == 0)
        #expect(try await harness.store.prStatus(repoID: harness.repo.id, prNumber: 52) == nil)
    }

    @Test("A card with nothing to look up costs nothing")
    func nothingToLookUpCostsNothing() async throws {
        // No pull request number **and** no issue number: with an issue number
        // `reconcile` finds the pull request by branch and fills the number in,
        // so "no pull request number" stops being true inside the same tick.
        let harness = try await makeHarness(prNumber: nil, issueNumber: nil)
        await harness.watcher.tick()
        #expect(harness.prViewCalls() == 0)
    }

    @Test("A pull request number reconcile discovers this tick is read this tick")
    func numberDiscoveredThisTickIsReadThisTick() async throws {
        // The other half of re-reading the cards after `reconcile`. On the stale
        // snapshot this card was still "no pull request number" and its first
        // reading waited a whole tick — up to ~6 minutes once the quiet backoff
        // has widened.
        let harness = try await makeHarness(prNumber: nil)
        await harness.watcher.tick()

        let card = try #require(try await harness.store.cards(repoID: harness.repo.id).first)
        #expect(card.prNumber == 52, "reconcile did not attach the pull request")
        #expect(harness.prViewCalls() == 1)
        #expect(try await harness.store.prStatus(repoID: harness.repo.id, prNumber: 52) != nil)
    }

    // MARK: - A failure leaves what was there

    @Test("A failed reading neither writes nor erases")
    func failedReadingLeavesThePreviousRow() async throws {
        let harness = try await makeHarness(prView: "does-not-exist.json")
        let previous = PRStatus(
            repoID: harness.repo.id, prNumber: 52,
            headRefOid: "0000000000000000000000000000000000000000",
            checkedAt: Date(timeIntervalSince1970: 1_000_000),
            rawMergeStateStatus: "CLEAN", rawMergeable: "MERGEABLE", rawReviewDecision: "",
            checks: [GHMergeStatus.StatusCheck(name: "build", conclusion: "SUCCESS", status: "COMPLETED")])
        try await harness.store.savePRStatus(previous)

        await harness.watcher.tick()

        // Unchanged: an unreachable `gh` is not evidence about the pull request,
        // and the row it left behind ages out on its own.
        #expect(try await harness.store.prStatus(repoID: harness.repo.id, prNumber: 52) == previous)
    }
}
