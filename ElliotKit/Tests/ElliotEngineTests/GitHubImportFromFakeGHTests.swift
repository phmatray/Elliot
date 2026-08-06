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

    /// A `GHClient` pointed at the fake, with `claudePath` and `gitPath` left
    /// empty on purpose: if the import ever reaches for either, the test should
    /// fail loudly rather than quietly use a real tool.
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
            claudePath: "", ghPath: Paths.fakeGH, gitPath: "", environment: environment))
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
