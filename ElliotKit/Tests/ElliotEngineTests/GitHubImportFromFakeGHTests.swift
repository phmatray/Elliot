import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import TestSupport
import Testing

@testable import ElliotEngine

/// #17 shipped with three of its eight acceptance criteria unproven — 4
/// (idempotence), 5 (a dismissal survives a refresh) and 7 (one unreachable
/// repository does not abort the pass) — because `GitHubImportService` takes a
/// concrete `GHClient` and nothing could hand it a repository's issues.
///
/// It turns out nothing needed to: `GHClient` spawns `config.ghPath`, so
/// pointing that at a script is the whole seam. This drives the **real**
/// subprocess, the **real** ISO-8601 decode, the **real** store writes and the
/// **real** `BoardService` funnel, with no network and without `gh` existing on
/// the machine — the same trick `Scripts/fake-claude.sh` plays for `claude`.
///
/// No production code changed to make this possible.
@Suite("GitHub import from a fake gh")
struct GitHubImportFromFakeGHTests {

    /// The repository root, from this file's own location, so the tests use the
    /// same `Scripts/` and `Fixtures/` a human would from a terminal.
    private enum Paths {
        static let repoRoot: URL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ElliotEngineTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ElliotKit
            .deletingLastPathComponent()   // repo root

        static let fakeGH = repoRoot.appendingPathComponent("Scripts/fake-gh.sh").path

        static func fixture(_ name: String) -> String {
            repoRoot.appendingPathComponent("Fixtures/gh/\(name)").path
        }
    }

    /// Records that nothing is ever asked of the scheduler — importing must not
    /// start a run, whatever column a card lands in.
    private actor RecordingLauncher: RunLaunching {
        private(set) var launched: [UUID] = []
        func launch(runID: UUID) async { launched.append(runID) }
        func cancel(runID: UUID) async {}
    }

    private struct Stack {
        var store: BoardStore
        var board: BoardService
        var launcher: RecordingLauncher
        var service: GitHubImportService
        var repo: Repo
    }

    /// A `GHClient` pointed at the fake, with `gitPath` left empty on purpose:
    /// if the import ever reaches for git, the test should fail loudly rather
    /// than quietly use a real tool.
    private func fakeClient(
        issues: String?,
        prs: String?,
        mode: String = "ok",
        argvOut: String? = nil
    ) -> GHClient {
        var environment = ["FAKE_GH_MODE": mode]
        if let issues { environment["FAKE_GH_ISSUES"] = Paths.fixture(issues) }
        if let prs { environment["FAKE_GH_PRS"] = Paths.fixture(prs) }
        if let argvOut { environment["FAKE_GH_ARGV_OUT"] = argvOut }
        return GHClient(config: ToolConfig(
            ghPath: Paths.fakeGH, gitPath: "", environment: environment))
    }

    private func stack(
        issues: String? = "issues-basic.json",
        prs: String? = "prs-basic.json",
        mode: String = "ok",
        argvOut: String? = nil,
        name: String = "Elliot",
        nameWithOwner: String = "phmatray/Elliot"
    ) async throws -> Stack {
        let store = try BoardStore.inMemory()
        let launcher = RecordingLauncher()
        let board = BoardService(store: store, launcher: launcher)
        let repo = Repo(
            path: "/tmp/elliot-\(UUID().uuidString)",
            nameWithOwner: nameWithOwner, displayName: name)
        try await store.saveRepo(repo)

        return Stack(
            store: store, board: board, launcher: launcher,
            service: GitHubImportService(
                store: store,
                gh: fakeClient(issues: issues, prs: prs, mode: mode, argvOut: argvOut),
                board: board),
            repo: repo)
    }

    /// A second service over the **same** store and board, answering with
    /// different fixtures — how "GitHub's answer changed since last time" is
    /// expressed without rebuilding the board underneath it.
    private func rewired(
        _ s: Stack, issues: String?, prs: String?, mode: String = "ok"
    ) -> GitHubImportService {
        GitHubImportService(
            store: s.store,
            gh: fakeClient(issues: issues, prs: prs, mode: mode),
            board: s.board)
    }

    /// Every wait is bounded. A wedged child holding the runner's stdout pipe is
    /// how `swift test` once stopped exiting and presented as a broken
    /// toolchain — the fake traps, and this is the second belt.
    private func importRepo(_ s: Stack) async throws -> ImportSummary {
        try await withTimeout(.seconds(30)) { await s.service.importRepo(s.repo) }
    }

    // MARK: - The path exists at all

    @Test("A first import creates a card per open unit, in the column the planner chose")
    func firstImportCreatesCards() async throws {
        let s = try await stack()
        let summary = try await importRepo(s)

        #expect(summary.failure == nil, "the fake must be reachable: \(summary.failure ?? "")")
        #expect(summary.created == 3)

        let cards = try await s.store.cards(repoID: s.repo.id)
        #expect(cards.count == 3)

        let byIssue = Dictionary(uniqueKeysWithValues: cards.compactMap { card in
            card.issueNumber.map { ($0, card) }
        })
        // 101: open, no pull request at all.
        #expect(byIssue[101]?.column == .todo)
        // 102: open pull request, not a draft → ready for review.
        #expect(byIssue[102]?.column == .inReview)
        #expect(byIssue[102]?.prNumber == 201)
        #expect(byIssue[102]?.branch == "feat/102-the-thing")
        // 103: open pull request, still a draft → in progress.
        #expect(byIssue[103]?.column == .inProgress)
        #expect(byIssue[103]?.prNumber == 202)

        // The whole point of importing through the funnel: no run is started,
        // whatever column a card lands in.
        #expect(await s.launcher.launched.isEmpty)
        #expect(try await s.store.runs(repoID: s.repo.id).isEmpty)
    }

    /// The closed-item asymmetry, half one: closed history is not a backlog.
    @Test("A closed issue no card tracks is not imported")
    func closedAndUntrackedIsNotImported() async throws {
        let s = try await stack()
        _ = try await importRepo(s)

        let cards = try await s.store.cards(repoID: s.repo.id)
        #expect(!cards.contains { $0.issueNumber == 104 }, "104 is closed and nothing tracks it")
    }

    @Test("The real gh argument list is what the service asked for")
    func argumentsAreReal() async throws {
        let argv = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-gh-argv-\(UUID().uuidString)").path
        let s = try await stack(argvOut: argv)
        _ = try await importRepo(s)

        let recorded = try String(contentsOfFile: argv, encoding: .utf8)
        #expect(recorded.contains("issue"))
        #expect(recorded.contains("pr"))
        #expect(recorded.contains("phmatray/Elliot"))
        // Proof the decode under test is the real one: the service asks for
        // these fields by name, and the fixtures answer with exactly them.
        #expect(recorded.contains("number,title,body,url,state,createdAt"))
        try? FileManager.default.removeItem(atPath: argv)
    }

    @Test("An empty repository is an all-zero summary, not a failure")
    func emptyIsNotAFailure() async throws {
        let s = try await stack(issues: nil, prs: nil)
        let summary = try await importRepo(s)

        #expect(summary.failure == nil)
        #expect(summary.created == 0)
        #expect(summary.adopted == 0)
        #expect(summary.unchanged == 0)
        #expect(try await s.store.cards(repoID: s.repo.id).isEmpty)
    }

    // MARK: - #17's criterion 4: ⌘R twice changes nothing

    @Test("Importing the same fixtures twice creates nothing and loses nothing")
    func secondPassChangesNothing() async throws {
        let s = try await stack()

        let first = try await importRepo(s)
        let afterFirst = try await s.store.cards(repoID: s.repo.id)
        #expect(first.created == 3)

        let second = try await importRepo(s)
        let afterSecond = try await s.store.cards(repoID: s.repo.id)

        // Nothing duplicated…
        #expect(second.created == 0)
        #expect(second.moved == 0)
        #expect(second.failure == nil)
        #expect(afterSecond.count == afterFirst.count)

        // …and nothing lost. A drop would be #29's defect in another costume:
        // an import that silently loses a row reads as a repository that has
        // less work than it does, so the count alone is not enough — the same
        // issue numbers have to still be there, on the same cards.
        #expect(Set(afterSecond.compactMap(\.issueNumber)) == Set(afterFirst.compactMap(\.issueNumber)))
        #expect(Set(afterSecond.map(\.id)) == Set(afterFirst.map(\.id)))
        #expect(second.unchanged == 3, "every unit reported unchanged on the second pass")

        // Still no run, on the second pass either.
        #expect(await s.launcher.launched.isEmpty)
    }

    @Test("A third pass is still a no-op — idempotence is not a one-off")
    func thirdPassAlsoChangesNothing() async throws {
        let s = try await stack()
        _ = try await importRepo(s)
        _ = try await importRepo(s)
        let third = try await importRepo(s)

        #expect(third.created == 0)
        #expect(third.unchanged == 3)
        #expect(try await s.store.cards(repoID: s.repo.id).count == 3)
    }

    // MARK: - #17's criterion 5: a dismissal survives a refresh

    @Test("A deleted card does not come back on the next refresh, and is counted as dismissed")
    func dismissalSurvivesRefresh() async throws {
        let s = try await stack()
        _ = try await importRepo(s)

        let imported = try await s.store.cards(repoID: s.repo.id)
        let doomed = try #require(imported.first { $0.issueNumber == 101 })
        try await s.board.deleteCard(id: doomed.id)
        #expect(try await s.store.cards(repoID: s.repo.id).count == 2)

        let second = try await importRepo(s)

        let after = try await s.store.cards(repoID: s.repo.id)
        #expect(!after.contains { $0.issueNumber == 101 }, "a dismissal is a decision, and it sticks")
        #expect(after.count == 2)
        #expect(second.created == 0)
        #expect(second.skippedDismissed >= 1, "and the summary says so rather than staying silent")
    }

    @Test("Forgetting the dismissals brings the card back on the next refresh")
    func clearDismissalsUndoesIt() async throws {
        let s = try await stack()
        _ = try await importRepo(s)
        let doomed = try #require(
            try await s.store.cards(repoID: s.repo.id).first { $0.issueNumber == 101 })
        try await s.board.deleteCard(id: doomed.id)
        _ = try await importRepo(s)
        #expect(try await s.store.cards(repoID: s.repo.id).count == 2)

        try await s.store.clearDismissals(repoID: s.repo.id)
        let third = try await importRepo(s)

        let after = try await s.store.cards(repoID: s.repo.id)
        #expect(after.contains { $0.issueNumber == 101 }, "un-dismissed means it may return")
        #expect(after.count == 3)
        #expect(third.created == 1)
        #expect(third.skippedDismissed == 0)
    }

    // MARK: - #334: one dismissal undone, and only that one

    /// Criterion 2, end to end and through the real subprocess: *restoring one
    /// removes only that row, and the next refresh brings the item back*.
    ///
    /// `clearDismissalsUndoesIt` above proves the bulk act, and it cannot
    /// distinguish "restored the one I pressed" from "restored everything" —
    /// which was the only undo the board had.
    @Test("Restoring one dismissal brings back that card and leaves the other suppressed")
    func restoringOneBringsBackOnlyThatCard() async throws {
        let s = try await stack()
        _ = try await importRepo(s)

        // Two separate units: issue 101 carries no pull request, issue 103
        // carries the draft PR 202.
        for number in [101, 103] {
            let doomed = try #require(
                try await s.store.cards(repoID: s.repo.id).first { $0.issueNumber == number })
            try await s.board.deleteCard(id: doomed.id)
        }
        let second = try await importRepo(s)
        #expect(second.created == 0)
        #expect(second.skippedDismissed >= 2)
        #expect(try await s.store.cards(repoID: s.repo.id).count == 1)

        try await s.store.undismiss(ExternalRef(kind: .issue, number: 101), repoID: s.repo.id)
        let third = try await importRepo(s)

        let after = try await s.store.cards(repoID: s.repo.id)
        #expect(after.contains { $0.issueNumber == 101 }, "the restored issue came back")
        #expect(
            !after.contains { $0.issueNumber == 103 },
            "and the one still dismissed stayed away — otherwise this is the bulk act again")
        #expect(third.created == 1)
        #expect(third.skippedDismissed >= 1)
    }

    /// The edge case the face's own footer describes, asserted rather than only
    /// written down: a card carrying **both** an issue and its pull request left
    /// two rows, and `plan` skips the unit if *either* is dismissed
    /// (`contains(where: dismissed.contains)`). So restoring one half changes
    /// nothing a reader can see, which is precisely why the list shows both.
    @Test("Restoring one half of a pair leaves the unit suppressed until both are back")
    func restoringOneHalfOfAPairKeepsTheUnitSuppressed() async throws {
        let s = try await stack()
        _ = try await importRepo(s)

        // Issue 102 is paired with PR 201 by its branch, so this one card holds
        // two refs and `deleteCard` writes two rows.
        let paired = try #require(
            try await s.store.cards(repoID: s.repo.id).first { $0.issueNumber == 102 })
        #expect(paired.prNumber == 201, "the fixture stopped pairing them; this test needs a pair")
        try await s.board.deleteCard(id: paired.id)

        let issue = ExternalRef(kind: .issue, number: 102)
        let pr = ExternalRef(kind: .pullRequest, number: 201)
        #expect(try await s.store.dismissals(repoID: s.repo.id) == [issue, pr])

        try await s.store.undismiss(issue, repoID: s.repo.id)
        _ = try await importRepo(s)
        #expect(
            try await s.store.cards(repoID: s.repo.id).allSatisfy { $0.issueNumber != 102 },
            "half a restore is not a restore: the pull request still suppresses the unit")

        try await s.store.undismiss(pr, repoID: s.repo.id)
        _ = try await importRepo(s)
        #expect(try await s.store.cards(repoID: s.repo.id).contains { $0.issueNumber == 102 })
    }

    // MARK: - #17's criterion 7: one unreachable repository is not the others' problem

    @Test("A gh failure becomes ImportSummary.failure rather than throwing out of importRepo")
    func failureIsReported() async throws {
        let s = try await stack(mode: "fail")
        let summary = try await importRepo(s)

        // The plan's one unverified assumption: `ProcessRunner.check` treats a
        // non-zero exit as a throw, and `importRepo` catches it into `failure`
        // rather than letting it escape. Verified here rather than believed.
        #expect(summary.failure != nil)
        #expect(summary.created == 0)
        #expect(try await s.store.cards(repoID: s.repo.id).isEmpty)
    }

    /// #17's criterion 7, stated exactly: in **one** pass, the unreachable
    /// repository fails and the healthy one is imported anyway.
    ///
    /// `importAll` shares a single `GHClient` across the pass, so a blanket
    /// `FAKE_GH_MODE=fail` can only show that both fail. `FAKE_GH_FAIL_REPO`
    /// makes the fake answer per `--repo`, which is what lets the two outcomes
    /// happen side by side.
    @Test("importAll keeps going: one unreachable repository does not cost the other its refresh")
    func oneBadRepoDoesNotAbortThePass() async throws {
        let store = try BoardStore.inMemory()
        let launcher = RecordingLauncher()
        let board = BoardService(store: store, launcher: launcher)

        let broken = Repo(
            path: "/tmp/elliot-broken-\(UUID().uuidString)",
            nameWithOwner: "phmatray/Broken", displayName: "Broken")
        let healthy = Repo(
            path: "/tmp/elliot-healthy-\(UUID().uuidString)",
            nameWithOwner: "phmatray/Healthy", displayName: "Healthy")
        try await store.saveRepo(broken)
        try await store.saveRepo(healthy)

        let config = ToolConfig(
            ghPath: Paths.fakeGH, gitPath: "",
            environment: [
                "FAKE_GH_ISSUES": Paths.fixture("issues-basic.json"),
                "FAKE_GH_PRS": Paths.fixture("prs-basic.json"),
                "FAKE_GH_FAIL_REPO": "phmatray/Broken",
            ])
        let service = GitHubImportService(
            store: store, gh: GHClient(config: config), board: board)

        let summaries = try await withTimeout(.seconds(30)) {
            await service.importAll([broken, healthy])
        }

        #expect(summaries.count == 2, "every repository is reported, including the one that failed")

        // Matched by name, not by position — `importAll` filters on `isEnabled`
        // so position is not an identity, which the disabled-repo case proves.
        let brokenSummary = try #require(summaries.first { $0.repoName == "Broken" })
        let healthySummary = try #require(summaries.first { $0.repoName == "Healthy" })

        #expect(brokenSummary.failure != nil, "the unreachable one says so")
        #expect(brokenSummary.created == 0)
        #expect(healthySummary.failure == nil, "and the reachable one was still refreshed")
        #expect(healthySummary.created == 3)

        // The board bears it out: one repository has its cards, the other none.
        #expect(try await store.cards(repoID: healthy.id).count == 3)
        #expect(try await store.cards(repoID: broken.id).isEmpty)
        #expect(await launcher.launched.isEmpty)
    }

    @Test("A disabled repository is skipped by importAll without being reported as failed")
    func disabledIsSkipped() async throws {
        let s = try await stack()
        let disabled = Repo(
            path: "/tmp/elliot-off-\(UUID().uuidString)",
            nameWithOwner: "phmatray/Off", displayName: "Off",
            isEnabled: false)
        try await s.store.saveRepo(disabled)

        let repo = s.repo
        let service = s.service
        let summaries = try await withTimeout(.seconds(30)) {
            await service.importAll([repo, disabled])
        }

        // `importAll` filters on `isEnabled`, so its output is *shorter* than
        // its input — the reason a caller must never match summaries to
        // repositories by position.
        #expect(summaries.count == 1)
        #expect(summaries[0].failure == nil)
        #expect(try await s.store.cards(repoID: disabled.id).isEmpty)
    }

    /// The closed-item asymmetry, half two — and the reason the filter is not
    /// simply "skip closed": an issue a card already tracks must still be
    /// reconciled when it closes, or the board keeps showing work that is over.
    @Test("A closed issue a card already tracks is reconciled, not ignored")
    func closedButTrackedIsReconciled() async throws {
        let s = try await stack()
        _ = try await importRepo(s)

        let before = try await s.store.cards(repoID: s.repo.id)
        let tracked = try #require(before.first { $0.issueNumber == 101 })
        #expect(tracked.column == .todo)

        // Same repository, same store, same board — only GitHub's answer
        // changed: 101 is now closed, and 104 is still closed-and-untracked.
        let service = rewired(s, issues: "issues-101-closed.json", prs: nil)
        let repo = s.repo
        let summary = try await withTimeout(.seconds(30)) { await service.importRepo(repo) }
        #expect(summary.failure == nil)

        let after = try await s.store.cards(repoID: s.repo.id)
        let reconciled = try #require(after.first { $0.issueNumber == 101 })
        #expect(reconciled.id == tracked.id, "reconciled in place, not re-created")
        #expect(reconciled.column == .done, "a tracked issue that closed is moved, not left in To Do")

        // The asymmetry, stated as one assertion: the closed issue a card
        // tracks moved; the closed issue nothing tracks still did not arrive.
        #expect(!after.contains { $0.issueNumber == 104 })

        // Reconciling a close is a system move, so it must not fire `merge-pr`.
        #expect(await s.launcher.launched.isEmpty)
    }
}
