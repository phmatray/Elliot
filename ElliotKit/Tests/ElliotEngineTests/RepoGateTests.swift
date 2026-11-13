import ElliotModel
import ElliotProcess
import Foundation
import TestSupport
import Testing

@testable import ElliotEngine

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

/// The seam between "what Preflight says" and "may an unattended agent start".
///
/// ⛔ **A gate answers a `PreflightState`, never a `Bool`, and that is the whole
/// point of the type.** The brief this was built from asked for
/// `blocks(_:) async -> Bool` over `PreflightService.isBlocking` — a function
/// deleted in #302 for being exactly the two-valued answer to a three-valued
/// question that let a gate be asserted in three documents and implemented in
/// none. A `Bool` here would put that shape back one layer up: a gate that could
/// not say *nobody looked* would have to say *fine*.
@Suite("Repository gating")
struct RepoGateTests {

    private let repo = Repo(
        path: "/tmp/elliot-not-a-repository-9f3a",
        nameWithOwner: "phmatray/Elliot", displayName: "Elliot"
    )

    private var preflight: PreflightService {
        service()
    }

    /// A `PreflightService` whose `git` and `gh` are both stated.
    ///
    /// ⚠️ **`git` defaults to a real one rather than `/usr/bin/false`, and that
    /// is the point.** A failing `git` makes *every* path answer "not a git
    /// repository", so a test built on it passes whatever the check under it
    /// does — including nothing at all.
    private func service(
        git: String = gitFixturePath, environment: [String: String] = [:]
    ) -> PreflightService {
        PreflightService(
            environment: LoginShellEnvironment(variables: [:], capturedVia: "test"),
            config: ToolConfig(
                ghPath: Paths.fakeGH,
                gitPath: git, environment: environment
            )
        )
    }

    /// A real checkout that Preflight has no finding against.
    ///
    /// `git init`, a committed `.claude/skills/repo-profile.md`, and a working
    /// tree left clean. Everything else in `repoChecks` that can *fail* is
    /// covered by those three: `repo.exists`, `repo.isMainCheckout`,
    /// `repo.profile` and — through `FAKE_GH_REPO_VIEW` — `repo.nameWithOwner`.
    /// The remaining rows can only reach `.warn`, which is not a refusal.
    private func healthyCheckout() async throws -> URL {
        // ⛔ **A refusal, not a skip.** `AnalysisEndToEndTests` falls back to
        // `/usr/bin/false` when git is absent; here that would turn the one
        // witness that the gate can say *yes* back into no witness at all, which
        // is precisely the hole this test was added to close. `/usr/bin/git`
        // ships with the Xcode command-line tools this package needs to build,
        // so a machine that fails here cannot build the package either.
        try #require(
            gitFixtureIsAvailable,
            "no /usr/bin/git — the passing-verdict witness cannot be built without a real checkout")

        let root = TestHome.scratch("repo-gate")
        let skills = root.appendingPathComponent(".claude/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        try "# profile\n".write(
            to: skills.appendingPathComponent("repo-profile.md"), atomically: true, encoding: .utf8)

        let env = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null"]
        for arguments in [
            ["init", "-q"],
            ["-c", "user.email=t@e.st", "-c", "user.name=T", "add", "."],
            ["-c", "user.email=t@e.st", "-c", "user.name=T", "commit", "-q", "-m", "seed"],
        ] {
            _ = try await ProcessRunner.run(
                executable: gitFixturePath, arguments: arguments, cwd: root.path,
                environment: env, timeout: .seconds(30))
        }
        return root
    }

    /// ⚠️ **`OpenGate` answers `notChecked`, not `passing`, and the difference is
    /// not academic.**
    ///
    /// It refuses nothing *today* — `UnattendedStartRefusal` lets `notChecked`
    /// through, for the reasons `PreflightState` writes out — so it is still the
    /// gate a caller reaches for when it has already decided. What it must not do
    /// is claim a sweep happened. `passing` here would be a caller saying "asked
    /// and clear" having asked nothing, which is the collapse `PreflightState`
    /// exists to prevent, planted in the one type whose name invites it.
    ///
    /// The consequence is deliberate and worth naming: the day `notChecked`
    /// starts refusing — which `PreflightState` says is one line in
    /// `evaluateMove` — every site holding an `OpenGate` starts refusing too, and
    /// has to state a verdict it has actually measured. That is the loud
    /// direction. `passing` would leave them all silently permitting.
    @Test("An open gate says nobody looked, rather than claiming a pass")
    func openGateSaysNobodyLooked() async {
        #expect(await OpenGate().verdict(for: repo) == .notChecked)
    }

    /// The rule's own answer for that state, asserted here rather than inherited.
    ///
    /// `UnattendedStartRefusalTests.notCheckedDoesNotRefuse` pins the rule. This
    /// pins what it means *for a service that spawns up to eight unattended
    /// `claude -p` runs at `bypassPermissions`*: a gate whose sweep never landed
    /// permits. It is consistent with the board and it is a decision, so it is
    /// written down at the caller that pays for it.
    @Test("A gate that never looked permits an unattended start")
    func nobodyLookedPermits() async {
        #expect(
            UnattendedStartRefusal.refusal(
                repo: repo, preflight: await OpenGate().verdict(for: repo)) == nil)
    }

    // MARK: - The real gate

    /// ⛔ **The witness that the real gate can say yes, and the one this suite
    /// shipped without.**
    ///
    /// Measured: with `PreflightGate.verdict` forced to a constant `.failing`,
    /// the whole package stayed green at 2432/2432 — and `AppModel` installs
    /// this gate for the running app, so that constant means *no analysis ever
    /// starts anywhere*, silently. A gate that always refuses and a gate that
    /// refuses correctly were the same thing to every test that existed.
    ///
    /// ⚠️ **I claimed this test could not be built, and the claim was false.**
    /// `Scripts/fake-gh.sh` already answered six subcommands rather than two,
    /// and `AnalysisEndToEndTests` already supplied a real checkout. The only
    /// genuine gap was `gh repo view`, which is the one *failing* check an
    /// unconfigured fake leaves behind once a real `git` is in play — 6 lines of
    /// harness, in the shape `pr view` already had. CLAUDE.md names this exact
    /// error from #40/#41: do not conclude a `gh`-backed path is untestable.
    /// Re-measure the harness before believing that.
    @Test("The real gate passes a checkout with no finding against it")
    func preflightGatePassesAHealthyRepository() async throws {
        let root = try await healthyCheckout()
        defer { try? FileManager.default.removeItem(at: root) }
        let healthy = Repo(
            path: root.path, nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        let service = service(
            environment: ["FAKE_GH_REPO_VIEW": Paths.fixture("repo-view.json")])

        // Named, so a future check that starts failing says which rather than
        // turning this into an unexplained red.
        let failing = await service.repoChecks(healthy).filter { $0.status == .fail }
        #expect(
            failing.isEmpty,
            Comment(rawValue: "failing checks: \(failing.map(\.id).joined(separator: ", "))"))

        #expect(await PreflightGate(preflight: service).verdict(for: healthy) == .passing)
    }

    /// The refusing direction, over a real `git` that really says no.
    ///
    /// ⚠️ **`gitPath` is a working `git` here, deliberately.** This test used
    /// `/usr/bin/false`, which makes *every* path fail to be a repository — so
    /// it passed for the wrong cause and would have passed with the
    /// `repo.exists` check deleted. The scratch directory is real and empty, and
    /// a real `git rev-parse` really refuses it.
    @Test("The real gate refuses a directory that is not a checkout, naming the check")
    func preflightGateRefusesANonRepository() async throws {
        let root = TestHome.scratch("repo-gate-bare")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let notARepo = Repo(
            path: root.path, nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        // The same `gh` fixture the passing case uses: the only difference
        // between the two is `git init`, so the verdict cannot be coming from
        // an unconfigured fake.
        let service = service(
            environment: ["FAKE_GH_REPO_VIEW": Paths.fixture("repo-view.json")])

        let results = await service.repoChecks(notARepo)
        #expect(results.contains { $0.id == "repo.exists" && $0.status == .fail })
        #expect(await PreflightGate(preflight: service).verdict(for: notARepo) == .failing)
    }

    /// A reading *is* somebody having looked, so the real gate has two answers
    /// and neither is the third.
    ///
    /// Both directions are asserted, because the claim is about the *type* of
    /// answer rather than about either repository: `PreflightReading.verdict` is
    /// `passing`/`failing` by construction, and `repoChecks` always appends at
    /// least `repo.exists`, so there is no input that produces `notChecked`
    /// here. That state belongs to a caller that did not ask.
    @Test("The real gate never answers notChecked, whichever way it goes")
    func preflightGateNeverSaysNobodyLooked() async throws {
        let root = try await healthyCheckout()
        defer { try? FileManager.default.removeItem(at: root) }
        let healthy = Repo(
            path: root.path, nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        let gate = PreflightGate(
            preflight: service(
                environment: ["FAKE_GH_REPO_VIEW": Paths.fixture("repo-view.json")]))

        #expect(await gate.verdict(for: healthy) != .notChecked)
        #expect(await gate.verdict(for: repo) != .notChecked)
    }
}
