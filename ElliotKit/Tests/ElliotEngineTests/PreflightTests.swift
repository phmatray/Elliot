import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import TestSupport
import Testing

@testable import ElliotEngine

/// Preflight's checks, and the fixes they may now carry.
///
/// Until #170 a `CheckResult` could only *describe* a remedy, in `fixHint`
/// prose, while the Repositories page had had actionable rows since #12
/// (`RepoFix` + `RepoRegistryService.apply`). Two screens, the same question —
/// *here is what is wrong, fix it* — and two different answers, only one of
/// which worked. These pin the mechanism that closes that, and the labels check
/// that is its first user.
@Suite("Preflight")
struct PreflightTests {

    // MARK: - The mechanism

    @Test("A check carries no fix unless it was given one")
    func fixesDefaultToNone() {
        // Every check that existed before #170 is constructed without this
        // argument, so the default decides whether the whole screen suddenly
        // grows buttons. It must not.
        let plain = CheckResult(
            id: "tool.git", title: "git", status: .pass, detail: "found"
        )
        #expect(plain.fixes.isEmpty)
    }

    @Test("Every check the service already produced still carries none")
    func existingChecksAreUnchanged() {
        // Asserted against a real check the service builds rather than one the
        // test made up: a default that only holds for hand-built values would
        // miss a construction site that started passing something.
        let root = PreflightService.repositoriesRootCheck(.portfolio)
        #expect(root.fixes.isEmpty)
    }

    @Test("A fix's label is the button's text, and names what it will do")
    func fixLabelsReadAsButtons() {
        let repoID = UUID()
        let create = CheckFix.createLabels(
            repoID: repoID, nameWithOwner: "phmatray/Elliot",
            labels: [RequiredLabel(name: "bug", color: "d73a4a", description: "x")]
        )
        let seed = CheckFix.seedCard(
            repoID: repoID,
            title: "Decide a label taxonomy",
            story: UserStory(role: "maintainer", want: "a taxonomy", benefit: "labelled issues")
        )

        #expect(!create.label.isEmpty)
        #expect(!seed.label.isEmpty)
        // Two fixes on one row must not read the same, or the reader cannot tell
        // the instant one from the one that files work.
        #expect(create.label != seed.label)
        // The deterministic one says how many it will make, because "Create
        // labels" on a row that lists four of them is a button whose blast
        // radius is guesswork.
        #expect(create.label.contains("1"))
    }

    // MARK: - The labels check

    private enum Paths {
        static let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ElliotEngineTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ElliotKit
            .deletingLastPathComponent()   // repo root

        static let fakeGH = repoRoot.appendingPathComponent("Scripts/fake-gh.sh").path
        static func fixture(_ name: String) -> String {
            repoRoot.appendingPathComponent("Fixtures/gh/\(name)").path
        }
    }

    private func service(_ environment: [String: String] = [:]) -> PreflightService {
        PreflightService(
            environment: LoginShellEnvironment(variables: [:], capturedVia: "test"),
            config: ToolConfig(
                claudePath: "/usr/bin/false",
                ghPath: Paths.fakeGH,
                gitPath: "/usr/bin/false",
                environment: environment
            )
        )
    }

    private let repo = Repo(
        path: "/tmp/elliot", nameWithOwner: "phmatray/Elliot", displayName: "Elliot"
    )

    @Test("Every required label present is a pass with nothing to do")
    func allPresentIsAPass() async {
        // The fixture carries bug and enhancement; the policy passed here asks
        // for exactly those, so there is nothing missing and nothing to offer.
        let check = await service(["FAKE_GH_LABELS": Paths.fixture("labels.json")])
            .labelsCheck(repo, required: [
                RequiredLabel(name: "bug", color: "d73a4a", description: "x"),
                RequiredLabel(name: "enhancement", color: "a2eeef", description: "y"),
            ])

        #expect(check.status == .pass)
        #expect(check.fixes.isEmpty)
    }

    @Test("A missing label is named, and two fixes are offered")
    func missingAreNamedAndFixable() async {
        let check = await service(["FAKE_GH_LABELS": Paths.fixture("labels.json")])
            .labelsCheck(repo, required: LabelPolicy.default)

        // `warn`, never `fail`: `PreflightReading.verdict` calls any `.fail`
        // "cards cannot be dragged", and a missing `documentation` label must
        // not freeze a board.
        #expect(check.status == .warn)
        // Each one named. "Some labels are missing" sends the reader to GitHub
        // to work out which.
        #expect(check.detail.contains("documentation"))
        #expect(check.detail.contains("question"))
        // And not the ones that are there.
        #expect(!check.detail.contains("enhancement"))

        #expect(check.fixes.count == 2)
        if case .createLabels(_, _, let labels) = check.fixes[0] {
            #expect(labels.map(\.name) == ["documentation", "question"])
        } else {
            Issue.record("the first fix should create the missing labels")
        }
        if case .seedCard = check.fixes[1] {} else {
            Issue.record("the second fix should seed a card")
        }
    }

    @Test("A gh that could not answer offers no fix at all")
    func unreachableOffersNothing() async {
        // #148's lesson, one screen over: a failure to *ask* is not a finding
        // about the answer. Reported as missing, every required label would be
        // listed for a repository nobody could reach — and a button under that
        // would create labels on the strength of a guess.
        let check = await service([
            "FAKE_GH_MODE": "fail",
            "FAKE_GH_LABELS": Paths.fixture("labels.json"),
        ]).labelsCheck(repo, required: LabelPolicy.default)

        #expect(check.status == .warn)
        #expect(check.fixes.isEmpty)
        #expect(check.detail.lowercased().contains("could not"))
        // It must not read as a verdict about the labels.
        #expect(!check.detail.contains("documentation"))
    }

    @Test("A repository with no labels at all is missing every one of them")
    func emptyRepositoryIsAFinding() async {
        // No fixture: the fake prints `[]`, which is what `gh` returns for a
        // repository with none. That is a *finding*, and must not be confused
        // with the unreachable case above.
        let check = await service().labelsCheck(repo, required: LabelPolicy.default)

        #expect(check.status == .warn)
        #expect(check.fixes.count == 2)
        if case .createLabels(_, _, let labels) = check.fixes[0] {
            #expect(labels.count == LabelPolicy.default.count)
        } else {
            Issue.record("expected a create-labels fix")
        }
    }

    @Test("A missing label never blocks a board")
    func missingLabelsAreNotBlocking() async {
        let check = await service().labelsCheck(repo, required: LabelPolicy.default)
        let reading = PreflightReading(results: [check], checkedAt: .now)
        #expect(reading.verdict == .passing)
        #expect(reading.blocking == nil)
    }

    // MARK: - Performing a fix

    private actor NeverLaunches: RunLaunching {
        private(set) var launched: [UUID] = []
        func launch(runID: UUID) async { launched.append(runID) }
        func cancel(runID: UUID) async {}
    }

    private func seededBoard() async throws -> (BoardStore, BoardService, NeverLaunches, Repo) {
        _ = TestHome.root
        let store = try BoardStore.inMemory()
        let launcher = NeverLaunches()
        let board = BoardService(store: store, launcher: launcher)
        var repo = self.repo
        repo.id = UUID()
        try await store.saveRepo(repo)
        return (store, board, launcher, repo)
    }

    @Test("Creating the missing labels asks gh once per label and counts them")
    func createLabelsRunsPerLabel() async throws {
        let (_, board, _, repo) = try await seededBoard()
        let argv = FileManager.default.temporaryDirectory
            .appendingPathComponent("preflight-argv-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: argv) }

        let missing = [
            RequiredLabel(name: "documentation", color: "0075ca", description: "docs"),
            RequiredLabel(name: "question", color: "d876e3", description: "q"),
        ]
        let outcome = await service(["FAKE_GH_ARGV_OUT": argv]).apply(
            .createLabels(repoID: repo.id, nameWithOwner: repo.nameWithOwner, labels: missing),
            repo: repo,
            board: board
        )

        #expect(outcome.succeeded)
        #expect(outcome.detail.contains("2"))

        let arguments = try String(contentsOfFile: argv, encoding: .utf8)
        #expect(arguments.contains("documentation"))
        #expect(arguments.contains("question"))
        // Two invocations, not one call with two names.
        #expect(arguments.components(separatedBy: "create").count - 1 == 2)
    }

    @Test("A partial failure names what failed and does not report success")
    func partialFailureIsNotSuccess() async throws {
        let (_, board, _, repo) = try await seededBoard()

        // Everything fails here, for a reason that is not already-exists — so
        // the outcome must say so rather than counting them as created.
        let outcome = await service([
            "FAKE_GH_MODE": "fail",
            "FAKE_GH_STDERR": "HTTP 403: Resource not accessible",
        ]).apply(
            .createLabels(
                repoID: repo.id, nameWithOwner: repo.nameWithOwner,
                labels: [RequiredLabel(name: "documentation", color: "0075ca", description: "d")]
            ),
            repo: repo,
            board: board
        )

        #expect(!outcome.succeeded)
        #expect(outcome.detail.contains("documentation"))
    }

    @Test("Seeding a card puts it in Backlog and starts nothing")
    func seedCardCreatesWithoutRunning() async throws {
        let (store, board, launcher, repo) = try await seededBoard()
        let story = UserStory(role: "maintainer", want: "a taxonomy", benefit: "labelled issues")

        let outcome = await service().apply(
            .seedCard(repoID: repo.id, title: "Decide a label taxonomy", story: story),
            repo: repo,
            board: board
        )

        #expect(outcome.succeeded)
        let cards = try await store.cards(repoID: repo.id)
        #expect(cards.count == 1)
        // Backlog, where nothing runs. A card seeded into `todo` would file an
        // issue about labels the moment the button was pressed — a button that
        // spawns an unattended agent is exactly what this design refuses.
        #expect(cards.first?.column == .backlog)
        #expect(cards.first?.story?.want == "a taxonomy")
        #expect(await launcher.launched.isEmpty)
    }

    @Test("Fixes are identifiable and hashable, so a view can list them")
    func fixesAreListable() {
        let repoID = UUID()
        let a = CheckFix.createLabels(repoID: repoID, nameWithOwner: "phmatray/Elliot", labels: [])
        let b = CheckFix.seedCard(
            repoID: repoID, title: "t",
            story: UserStory(role: "r", want: "w", benefit: "b")
        )
        #expect(a.id != b.id)
        #expect(Set([a, b]).count == 2)

        // And a `CheckResult` carrying them still hashes — the type is `Hashable`
        // and SwiftUI leans on that for the row's identity.
        let result = CheckResult(
            id: "repo.labels", title: "Labels", status: .warn, detail: "d", fixes: [a, b]
        )
        #expect(Set([result]).count == 1)
        #expect(result.fixes.count == 2)
    }

    @Test("The button writes to the repository the check asked about")
    func fixCarriesTheResolvedName() async {
        // The stored `Repo.nameWithOwner` and the live one diverge: both
        // registration paths fall back to a bare directory name when `gh` was
        // unavailable, and nothing repairs it. A fix built from the stored value
        // would run `gh label create --repo Elliot` — rejected for not being
        // OWNER/REPO — for a finding that was perfectly right.
        var stale = repo
        stale.nameWithOwner = "Elliot"

        let check = await service().labelsCheck(
            stale, nameWithOwner: "phmatray/Elliot", required: LabelPolicy.default
        )

        guard case .createLabels(_, let nameWithOwner, _) = check.fixes[0] else {
            Issue.record("expected a create-labels fix")
            return
        }
        #expect(nameWithOwner == "phmatray/Elliot")
    }

    @Test("Pressing Add a card twice leaves one card, not two")
    func seedCardIsIdempotent() async throws {
        // The button does not go away after a press: the labels are still
        // missing, so the row is rebuilt with the same two fixes. Without a key
        // an impatient second press writes a second identical card.
        let (store, board, _, repo) = try await seededBoard()
        let fix = CheckFix.seedCard(
            repoID: repo.id, title: "Decide a label taxonomy",
            story: UserStory(role: "r", want: "w", benefit: "b")
        )

        _ = await service().apply(fix, repo: repo, board: board)
        _ = await service().apply(fix, repo: repo, board: board)

        #expect(try await store.cards(repoID: repo.id).count == 1)
    }

    @Test("A label that already existed is not reported as created")
    func alreadyThereIsSaidApart() async throws {
        // `labels()` reads one page, so a repository past that limit can hold a
        // label the check called missing. Calling it "created" would put a
        // sentence beside a row that still says it is missing.
        let (_, board, _, repo) = try await seededBoard()
        let outcome = await service([
            "FAKE_GH_MODE": "fail",
            "FAKE_GH_STDERR": "already exists",
        ]).apply(
            .createLabels(
                repoID: repo.id, nameWithOwner: repo.nameWithOwner,
                labels: [RequiredLabel(name: "question", color: "d876e3", description: "q")]
            ),
            repo: repo, board: board
        )

        #expect(outcome.succeeded)
        #expect(outcome.detail.contains("already existed"))
        #expect(!outcome.detail.contains("Created"))
    }
}
