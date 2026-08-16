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
            story: UserStory(role: "maintainer", want: "a taxonomy", benefit: "labelled issues"),
            key: nil
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
        let declared = LabelPolicy.Resolved(
            required: [
                RequiredLabel(name: "bug", color: "d73a4a", description: "x"),
                RequiredLabel(name: "enhancement", color: "a2eeef", description: "y"),
            ],
            source: .repository
        )
        let check = await service(["FAKE_GH_LABELS": Paths.fixture("labels.json")])
            .labelsCheck(repo, policy: declared)

        #expect(check.status == .pass)
        // Nothing to offer, because this repository has *answered* the taxonomy
        // question. Until #200 the same assertion held for a repository that
        // had never been asked, which is how the `seedCard` fix came to be
        // unreachable on exactly the repositories that needed it.
        #expect(check.fixes.isEmpty)
        #expect(check.detail == "All 2 labels this repository requires are present.")
    }

    @Test("A missing label is named, and two fixes are offered")
    func missingAreNamedAndFixable() async {
        let check = await service(["FAKE_GH_LABELS": Paths.fixture("labels.json")])
            .labelsCheck(repo, policy: LabelPolicy.Resolved(required: LabelPolicy.default, source: .elliotFloor))

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
        ]).labelsCheck(repo, policy: LabelPolicy.Resolved(required: LabelPolicy.default, source: .elliotFloor))

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
        let check = await service().labelsCheck(repo, policy: LabelPolicy.Resolved(required: LabelPolicy.default, source: .elliotFloor))

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
        let check = await service().labelsCheck(repo, policy: LabelPolicy.Resolved(required: LabelPolicy.default, source: .elliotFloor))
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
            .seedCard(repoID: repo.id, title: "Decide a label taxonomy", story: story, key: nil),
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
            story: UserStory(role: "r", want: "w", benefit: "b"),
            key: nil
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
            stale, nameWithOwner: "phmatray/Elliot", policy: LabelPolicy.Resolved(required: LabelPolicy.default, source: .elliotFloor)
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
            story: UserStory(role: "r", want: "w", benefit: "b"),
            key: nil
        )

        _ = await service().apply(fix, repo: repo, board: board)
        _ = await service().apply(fix, repo: repo, board: board)

        #expect(try await store.cards(repoID: repo.id).count == 1)
    }

    // MARK: - The rows that describe the binary that actually runs (#381, task 16)

    /// A scratch `PATH` holding nothing but stub `node`/`npx` executables, so these tests say the
    /// same thing on a machine with Node 26 and on one with none at all.
    ///
    /// Copied in shape from `ACPAgentLocatorTests.scratchToolchain` — parameterised by the `node`
    /// stub's script **body** rather than a version string, because "answers nothing" and
    /// "answers v20" are the two different failures this row has to tell apart.
    private func scratchToolchain(nodeBody: String) throws -> (
        env: LoginShellEnvironment, directory: String, remove: () -> Void
    ) {
        let dir = "/private/tmp/preflight-acp-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try stub("node", body: nodeBody, at: dir)
        try stub("npx", body: "echo \"10.9.0\"", at: dir)
        return (LoginShellEnvironment(variables: ["PATH": dir], capturedVia: "test"), dir, {
            try? FileManager.default.removeItem(atPath: dir)
        })
    }

    private func stub(_ name: String, body: String, at directory: String) throws {
        let path = (directory as NSString).appendingPathComponent(name)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    /// A service whose adapter is `Scripts/fake-acp.py` — a real child, a real handshake, no
    /// network and no `npx`.
    private func adapterService(
        environment: LoginShellEnvironment = LoginShellEnvironment(
            variables: [:], capturedVia: "test"),
        childEnvironment: [String: String] = [:]
    ) -> PreflightService {
        PreflightService(
            environment: environment,
            config: ToolConfig(
                claudePath: "/usr/bin/false",
                adapterExecutable: "/usr/bin/env",
                adapterArguments: [
                    "python3", Paths.repoRoot.appendingPathComponent("Scripts/fake-acp.py").path,
                ],
                ghPath: Paths.fakeGH,
                gitPath: "/usr/bin/git",
                environment: childEnvironment.merging(
                    ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], uniquingKeysWith: { a, _ in a })
            )
        )
    }

    @Test("the claude row is gone, and the adapter rows have taken its place")
    func theClaudeRowIsRetired() async {
        let ids = Set(await adapterService().globalChecks(packs: []).map(\.id))
        #expect(!ids.contains("tool.claude"))
        #expect(ids.isSuperset(of: ["tool.node", "tool.npx", "agent.adapter", "agent.commands"]))
    }

    @Test("an adapter answering a version other than the pin is a warning, not a pass")
    func aVersionDriftIsAWarning() async {
        // `fake-acp.py` answers `agentInfo` `fake-acp 0.0.1`, which is not the pin — so this is
        // the drift case without anything having to be stubbed for it.
        let results = await adapterService().globalChecks(packs: [])
        guard let adapter = results.first(where: { $0.id == "agent.adapter" }) else {
            Issue.record("expected an agent.adapter row")
            return
        }
        // ⚠️ A pin that has silently stopped being what runs is worse than no pin (decision 10),
        // so this is neither a pass nor a failure: the adapter answered, and it is not the one
        // every fixture in this design was measured against.
        #expect(adapter.status == .warn)
        #expect(adapter.detail.contains("0.0.1"))
        #expect(adapter.detail.contains(ACPAgentLocator.adapterVersion))
    }

    @Test("Node below 22 fails by name and says the number it found")
    func oldNodeFails() async throws {
        let (env, _, remove) = try scratchToolchain(nodeBody: "echo \"v20.11.1\"")
        defer { remove() }

        let results = await adapterService(environment: env).globalChecks(packs: [])
        guard let node = results.first(where: { $0.id == "tool.node" }) else {
            Issue.record("expected a tool.node row")
            return
        }
        #expect(node.status == .fail)
        #expect(node.detail.contains("v20.11.1"))
        #expect(node.detail.contains("\(ACPAgentLocator.minimumNodeMajor)"))
    }

    /// ⛔ The three-valued answer task 5 refused to collapse, one layer up.
    ///
    /// `resolveNode()` has three outcomes, not two: found-and-readable, found-but-unreadable, and
    /// not-found. The plan prescribed only two fail renderings — *"Not found."* and *"Found X, but
    /// the adapter needs 22 or newer."* — and a `.found` tool whose `version` is nil would have
    /// rendered as `"Found " + nothing`. **Elliot never established that a Node it could not read
    /// is old, and saying so is worse than refusing.**
    @Test("a node whose version cannot be read is not reported as too old")
    func unreadableNodeIsNotCalledOld() async throws {
        let (env, directory, remove) = try scratchToolchain(nodeBody: "exit 1")
        defer { remove() }

        let results = await adapterService(environment: env).globalChecks(packs: [])
        guard let node = results.first(where: { $0.id == "tool.node" }) else {
            Issue.record("expected a tool.node row")
            return
        }
        // Not a pass — nothing was established — and not a `.fail` either, which on this screen
        // means "cards cannot be dragged" for a toolchain that may be perfectly fine.
        #expect(node.status == .warn)
        #expect(node.detail.contains((directory as NSString).appendingPathComponent("node")))
        // ⛔ The sentence the two-valued rendering would have produced.
        #expect(!node.detail.contains("22 or newer"))
        #expect(!node.detail.contains("Found ,"))
    }

    @Test("the adapter names the commands it advertises, and the three Elliot dispatches")
    func advertisedCommandsAreNamed() async throws {
        let commands = "/private/tmp/preflight-commands-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: commands) }
        try Data(
            """
            [{"name": "ai-migration-kit:create-issue", "description": "x"},
             {"name": "ai-migration-kit:implement-issue", "description": "y"},
             {"name": "ai-migration-kit:merge-pr", "description": "z"},
             {"name": "superpowers:brainstorming", "description": "w"}]
            """.utf8
        ).write(to: URL(fileURLWithPath: commands))

        // The packs `AppModel` passes on a machine with nothing registered — which folds the
        // default in, so the three commands looked for are the ones this board dispatches.
        let results = await adapterService(childEnvironment: ["FAKE_ACP_COMMANDS": commands])
            .globalChecks(packs: PreflightService.packsInUse([]))
        guard let advertised = results.first(where: { $0.id == "agent.commands" }) else {
            Issue.record("expected an agent.commands row")
            return
        }
        #expect(advertised.status == .pass)
        #expect(advertised.detail.contains("4"))
        #expect(advertised.detail.contains("ai-migration-kit:merge-pr"))
    }

    /// ⛔ *"The adapter advertises none"* and *"nobody could ask"* are different facts, and a row
    /// that listed all three as missing would be reporting the first on the evidence of the
    /// second — `isBlocking([])`'s two-valued answer, one screen over.
    @Test("commands that were never established are not reported as missing")
    func unestablishedCommandsAreNotMissing() async {
        // No `FAKE_ACP_COMMANDS`, so the double opens a session and advertises nothing at all —
        // which is what an adapter that never sends the notification looks like from here.
        //
        // ⚠️ **`packsInUse([])`, not `[]`, and the difference is the whole test.** With no packs
        // there is nothing to look for, so collapsing nil into `[]` renders a confident *pass* —
        // red, but not the rendering this test is named for. With the default pack folded in, the
        // same collapse produces `Missing: ai-migration-kit:create-issue, …`: three commands
        // reported absent on the evidence of a question nobody got to ask. Measured by breaking it
        // both ways.
        let results = await adapterService().globalChecks(packs: PreflightService.packsInUse([]))
        guard let advertised = results.first(where: { $0.id == "agent.commands" }) else {
            Issue.record("expected an agent.commands row")
            return
        }
        #expect(advertised.status == .warn)
        #expect(advertised.detail.lowercased().contains("could not be established"))
        #expect(!advertised.detail.contains("Missing:"))
        #expect(!advertised.detail.contains("ai-migration-kit:create-issue"))
    }

    /// ⛔ An operator who set `ELLIOT_CLAUDE_PATH` and reads a green Preflight gets a binary they
    /// did not choose: the adapter runs the CLI vendored inside its own npm dependency.
    @Test("ELLIOT_CLAUDE_PATH is named where it stopped meaning anything")
    func theClaudeOverrideIsNamedWhereItDies() async {
        let results = await adapterService().globalChecks(
            packs: [], overrides: ToolOverrides(["claude": "/usr/bin/true"]))
        guard let row = results.first(where: { $0.id == "tool.claudeOverride" }) else {
            Issue.record("expected a row naming ELLIOT_CLAUDE_PATH")
            return
        }
        #expect(row.status == .warn)
        #expect(row.detail.contains("CLAUDE_CODE_EXECUTABLE"))
        // ⚠️ Whether pointing that at a local install works is UNMEASURED, and the row says so
        // rather than implying somebody checked.
        #expect(row.detail.lowercased().contains("unmeasured"))
    }

    @Test("no ELLIOT_CLAUDE_PATH, no row about it")
    func theClaudeOverrideRowIsSilentWhenUnset() async {
        let results = await adapterService().globalChecks(packs: [], overrides: ToolOverrides())
        #expect(!results.contains { $0.id == "tool.claudeOverride" })
    }

    // MARK: - Run terms, met before a drag rather than after

    private func checkout() async throws -> (path: String, remove: () -> Void) {
        let path = "/private/tmp/preflight-runterms-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        _ = try await ProcessRunner.run(
            executable: "/usr/bin/git",
            arguments: ["-C", path, "init", "--initial-branch=main"],
            environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(),
                          "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"],
            timeout: .seconds(30)
        )
        return (path, { try? FileManager.default.removeItem(atPath: path) })
    }

    @Test("a repository with extra allowed tools warns before a drag, not after")
    func runTermsWarn() async throws {
        // Ties to task 6's refusal: `AgentRun.start` throws `unmappableAllowedTools` before it
        // spawns anything, so *every* run in this repository refuses to start. Meeting that on a
        // screen beats meeting it as a failed card.
        let (path, remove) = try await checkout()
        defer { remove() }
        var subject = Repo(path: path, nameWithOwner: "phmatray/sandbox", displayName: "sandbox")
        subject.extraAllowedTools = ["Bash(git push:*)"]

        let results = await adapterService().repoChecks(subject)
        guard let terms = results.first(where: { $0.id == "repo.runTerms" }) else {
            Issue.record("expected a repo.runTerms row")
            return
        }
        #expect(terms.status == .fail)
        #expect(terms.detail.contains("Bash(git push:*)"))
        #expect(terms.fixHint?.contains("Run terms") == true)
    }

    @Test("a repository that allows nothing extra grows no row at all")
    func runTermsIsSilentWhenEmpty() async throws {
        let (path, remove) = try await checkout()
        defer { remove() }
        let subject = Repo(path: path, nameWithOwner: "phmatray/sandbox", displayName: "sandbox")

        let results = await adapterService().repoChecks(subject)
        #expect(!results.contains { $0.id == "repo.runTerms" })
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
