import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import TestSupport
import Testing

@testable import ElliotEngine

/// Preflight, once a repository can choose what Elliot runs there.
///
/// Two verdicts carry this whole suite and they are one character apart:
///
/// - **a missing project artefact is a `.warn`, never a `.fail`.** Since #249 a
///   `.fail` blocks every drag in that repository, so a repository without a PRD
///   would be frozen for lacking a file it has every right not to have.
/// - **an unknown `methodID` is a `.fail`.** We do not know what to run there,
///   and running a different method's commands unannounced is worse than
///   refusing — that is the silent substitution `MethodResolution` exists to stop.
///
/// The end-to-end tests drive `repoChecks` against a real `git init` under the
/// temporary directory, because a suite that only exercised the pure statics
/// would stay green if `repoChecks` stopped calling them — the gap
/// `CaretAnchorTests` was written to close, one screen over.
@Suite("Preflight methods")
struct PreflightMethodTests {

    private enum Paths {
        static let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ElliotEngineTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ElliotKit
            .deletingLastPathComponent()   // repo root

        static let fakeGH = repoRoot.appendingPathComponent("Scripts/fake-gh.sh").path
    }

    /// A real `git`, a fake `gh`, no network and no token.
    ///
    /// `gh repo view` is not a subcommand the fake answers, so it exits 64 and
    /// `repoInfo` comes back nil — which is what a checkout with no GitHub
    /// remote looks like, and it keeps the labels check (and its network call)
    /// out of every test here.
    private func service() -> PreflightService {
        PreflightService(
            environment: LoginShellEnvironment(variables: [:], capturedVia: "test"),
            config: ToolConfig(
                ghPath: Paths.fakeGH,
                gitPath: "/usr/bin/git",
                environment: [
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "HOME": NSHomeDirectory(),
                    "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
                    "GIT_TERMINAL_PROMPT": "0",
                ]
            )
        )
    }

    /// An empty checkout Elliot can legally sweep: a main checkout, on a branch,
    /// with nothing in it — which is exactly "every project requirement missing".
    private func checkout() async throws -> (path: String, remove: () -> Void) {
        let path = "/private/tmp/elliot-method-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try await git(["init", "--initial-branch=main"], in: path)
        return (path, { try? FileManager.default.removeItem(atPath: path) })
    }

    private func repo(at path: String, methodID: String?) -> Repo {
        var repo = Repo(path: path, nameWithOwner: "phmatray/sandbox", displayName: "sandbox")
        repo.methodID = methodID
        return repo
    }

    /// The pack a project-requirement test can be written against without
    /// guessing what the catalogue named things.
    private func packWithRequirements() throws -> MethodPack {
        try #require(
            MethodCatalog.builtIn.first { !$0.projectRequirements.isEmpty },
            "wave 1 must ship at least one pack carrying project requirements"
        )
    }

    // MARK: - The two verdicts

    @Test("A missing project artefact warns, and warning never freezes the board")
    func missingArtefactWarnsAndDoesNotBlock() async throws {
        let pack = try packWithRequirements()
        let (path, remove) = try await checkout()
        defer { remove() }

        let results = await service().repoChecks(repo(at: path, methodID: pack.id))
        let method = results.filter { $0.id.hasPrefix("method.\(pack.id).") }

        // Every requirement is a gap in an empty checkout, and every gap is one
        // check. This is also what stops `repoChecks` quietly ceasing to call
        // `projectResults`: the statics below are tested directly, this is not.
        #expect(method.count == pack.projectRequirements.count)
        #expect(method.allSatisfy { $0.status == .warn })
        // ⛔ The claim #249 made load-bearing. A repository without a PRD still
        // works; freezing it would be absurd.
        //
        // Asked through `PreflightReading` because `PreflightService.isBlocking`
        // was deleted by #302 — two names for one question, and the survivor is
        // the one that cannot be built without the moment it was taken at.
        #expect(PreflightReading(results: method, checkedAt: .now).verdict == .passing)
    }

    @Test("Each gap carries a card seeded under the requirement's own key")
    func gapsSeedCardsKeyedByRequirement() async throws {
        let pack = try packWithRequirements()
        let requirement = pack.projectRequirements[0]
        let (path, remove) = try await checkout()
        defer { remove() }

        let subject = repo(at: path, methodID: pack.id)
        let results = await service().repoChecks(subject)
        let check = try #require(results.first { $0.id == "method.\(pack.id).\(requirement.id)" })

        #expect(check.fixHint == requirement.remedy)
        let fix = try #require(check.fixes.first)
        // ⛔ Built through the one function that builds it, and it CARRIES THE
        // REPOSITORY. `apply` passes `fix.id` straight into
        // `createCard(idempotencyKey:)`, and `card_on_idempotencyKey` is unique
        // board-wide, so a repo-free key would hand the second repository to
        // choose this method the first one's card while reporting
        // "Added a card to Backlog."
        #expect(fix.id == pack.idempotencyKey(for: requirement, in: subject.id))
        #expect(fix.id.contains(subject.id.uuidString))
        #expect(fix.repoID == subject.id)
        #expect(fix.label == "Add a card")
    }

    @Test("A requirement that is satisfied produces no check at all")
    func satisfiedRequirementsAreSilent() async throws {
        let pack = try packWithRequirements()
        let (path, remove) = try await checkout()
        defer { remove() }

        let requirement = pack.projectRequirements[0]
        let relative: String
        switch requirement.evidence {
        case .file(let named): relative = named
        case .anyFileUnder(let directory): relative = directory + "/seeded.md"
        }
        let url = URL(fileURLWithPath: path).appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# there\n".utf8).write(to: url)

        let results = await service().repoChecks(repo(at: path, methodID: pack.id))
        #expect(!results.contains { $0.id == "method.\(pack.id).\(requirement.id)" })
    }

    @Test("An unknown method fails, blocks, and names what it was set to")
    func unknownMethodBlocks() async throws {
        let (path, remove) = try await checkout()
        defer { remove() }

        let results = await service().repoChecks(repo(at: path, methodID: "no-such-method"))
        let check = try #require(results.first { $0.id == "repo.method" })

        #expect(check.status == .fail)
        #expect(PreflightReading(results: [check], checkedAt: .now).verdict == .failing)
        #expect(check.detail.contains("no-such-method"))
        // And nothing was probed on its behalf: we do not know which artefacts
        // to look for, so reporting gaps would be reporting another method's.
        #expect(!results.contains { $0.id.hasPrefix("method.") })
    }

    @Test("A repository that never chose reads as unset, not as a choice")
    func unsetIsItsOwnState() async throws {
        let (path, remove) = try await checkout()
        defer { remove() }

        let check = try #require(
            await service().repoChecks(repo(at: path, methodID: nil))
                .first { $0.id == "repo.method" })
        #expect(check.status == .pass)
        // "Not chosen" and "chose the default" are the same commands and two
        // different facts, and only one of them follows the default if it moves.
        #expect(check.detail.lowercased().contains("not chosen"))
    }

    // MARK: - Refusing to guess

    @Test("A probe that refused produces one warning naming the cause, not N false gaps")
    func unreadableCheckoutIsOneWarning() throws {
        let pack = try packWithRequirements()
        let subject = repo(at: "/private/tmp/elliot-absent-\(UUID())", methodID: pack.id)

        var thrown: (any Error)?
        do {
            _ = try ArtifactProbe(repoRoot: subject.path)
                .evaluate(pack.projectRequirements.map(\.evidence))
        } catch {
            thrown = error
        }
        let check = PreflightService.probeRefusal(
            pack: pack, repo: subject, error: try #require(thrown))

        #expect(check.status == .warn)
        #expect(check.detail.lowercased().contains("could not be established"))
        // ⛔ It must not read as a verdict about the artefacts. "I could not
        // look" is not "there is nothing there" — the same duty `labelsCheck`
        // discharges when `gh` does not answer.
        #expect(!check.detail.contains(pack.projectRequirements[0].title))
        #expect(check.fixes.isEmpty)
    }

    /// ⛔ The refusal reached through the code path that will actually run it.
    ///
    /// `repoChecks` returns early on `guard isRepo` (`PreflightService.swift:335`),
    /// which covers every case `ArtifactProbe` throws `.unreadable` for — so by
    /// the time the probe runs, the root is a readable git directory and the
    /// `catch` is reachable only from **malformed pack evidence**. Calling
    /// `probeRefusal` directly (the test above) leaves that arm untested, and
    /// deleting it would keep every test green. `projectResults` exists so this
    /// one can drive the arm with a hand-built pack.
    @Test("Malformed pack evidence reaches the refusal instead of crashing the sweep")
    func malformedPackEvidenceReachesTheRefusal() async throws {
        let (path, remove) = try await checkout()
        defer { remove() }

        let broken = MethodPack(
            id: "broken", displayName: "Broken", summary: "s", plugin: .none,
            projectRequirements: [
                ProjectRequirement(
                    id: "escape", title: "An artefact outside the checkout",
                    evidence: .file("../elsewhere.md"), remedy: "Fix the pack.",
                    seed: CardDraft(
                        title: "Fix the pack", role: "maintainer", want: "a valid path",
                        benefit: "the probe can look", criteria: ["The path is relative."]))
            ]
        )
        let results = await service().projectResults(repo: repo(at: path, methodID: nil), pack: broken)

        let refusal = try #require(results.first, "a refusal must still produce a row")
        #expect(results.count == 1, "one warning, never one per requirement")
        #expect(refusal.id == "method.broken.probe")
        #expect(refusal.status == .warn)
        #expect(refusal.fixes.isEmpty)
    }

    // MARK: - The plugin, and the method that has none

    @Test("A method that is not a plugin is skipped, never failed")
    func noPluginIsSkipped() async {
        let plain = MethodPack(
            id: "plan-mode", displayName: "Plan mode",
            summary: "Claude Code's own plan mode. Nothing is written to disk.",
            plugin: .none, projectRequirements: [], steps: [:]
        )
        let results = await service().globalChecks(layout: .portfolio, packs: [plain])

        // No row at all. A method that needs no plugin must not read as a method
        // whose plugin is missing — that is a `.fail` for a correct setup.
        #expect(!results.contains { $0.id == "plugin.plan-mode" })
        // And the global sweep still ran everything else.
        #expect(results.contains { $0.id == "plugin.superpowers" })
    }

    /// The third value of `PluginRequirement`, and the one silence would have
    /// hidden: nothing is established as missing, so this must warn — never a
    /// silent skip (that reads as "checked, fine") and never a `.fail` (nothing
    /// is shown to be absent).
    @Test("A pack whose plugin is unestablished warns, carrying the reason")
    func unestablishedPluginWarnsWithReason() async {
        let uncertain = MethodPack(
            id: "uncertain", displayName: "Uncertain Method",
            summary: "s",
            plugin: .unestablished(reason: "nobody has published a /plugin install line"),
            projectRequirements: [], steps: [:]
        )
        let results = await service().globalChecks(layout: .portfolio, packs: [uncertain])
        let row = results.first { $0.id == "plugin.uncertain" }

        #expect(row?.status == .warn)
        #expect(row?.detail.contains("nobody has published a /plugin install line") == true)
    }

    /// Severity rule 4, driven through `globalChecks` rather than only through
    /// the pure `requiredSkills(of:)` helper `requiredSkillsComeFromTheSteps`
    /// exercises below. A regression that dropped the `.required` arm — folded
    /// it into `.none`'s `continue`, or hardcoded `.pass` regardless of what
    /// `pluginCheck` found — would leave every other test in this file green;
    /// this is the one that would catch it, because the plugin name is chosen
    /// so it can never actually be installed on the machine running the suite.
    @Test("A required plugin that is not installed fails, through globalChecks")
    func requiredPluginMissingFailsThroughGlobalChecks() async {
        let missing = MethodPack(
            id: "missing-plugin", displayName: "Missing Plugin", summary: "s",
            plugin: .required("elliot-test-plugin-that-will-never-be-installed"),
            projectRequirements: [], steps: [:]
        )
        let results = await service().globalChecks(layout: .portfolio, packs: [missing])
        let row = results.first { $0.id == "plugin.missing-plugin" }

        #expect(row?.status == .fail)
        #expect(row?.detail.contains("Not installed") == true)
    }

    @Test("A plugin pack is checked for the skills its own steps name")
    func requiredSkillsComeFromTheSteps() throws {
        let kit = try #require(
            MethodCatalog.builtIn.first { $0.id == MethodCatalog.defaultPackID })
        // Alphabetical, because a dictionary has no order and a check whose
        // detail string reshuffled between sweeps would read as movement.
        #expect(
            PreflightService.requiredSkills(of: kit)
                == ["create-issue", "implement-issue", "merge-pr"])

        // A command that does not name a plugin skill contributes none. GSD's
        // `/gsd-plan-phase` is a command, not `plugin:skill`, so there is no
        // `SKILL.md` to look for.
        let gsdShaped = MethodPack(
            id: "gsd-shaped", displayName: "GSD", summary: "s", plugin: .required("gsd"),
            projectRequirements: [],
            steps: [.createIssue: StepSpec(
                command: "/gsd-plan-phase", arguments: .ideaThenLabels, prose: "p {}")]
        )
        #expect(PreflightService.requiredSkills(of: gsdShaped).isEmpty)
    }

    @Test("The profile freezes a board only for a method whose skills read it")
    func profileFailsOnlyForSkillDispatchingMethods() async throws {
        let (path, remove) = try await checkout()
        defer { remove() }

        // Today's behaviour, unchanged: the default pack dispatches three plugin
        // skills, all of which read the profile at their preconditions step.
        let unset = await service().repoChecks(repo(at: path, methodID: nil))
        #expect(try #require(unset.first { $0.id == "repo.profile" }).status == .fail)

        // And the rule that made that conditional rather than hardcoded.
        #expect(PreflightService.profileHint(nil).contains("by hand"))
        let kit = try #require(
            MethodCatalog.builtIn.first { $0.id == MethodCatalog.defaultPackID })
        #expect(PreflightService.profileHint(kit).contains("/ai-migration-kit:get-repo-profile"))
    }

    /// The other half of the conditional above, driven through `repoChecks`
    /// rather than only asserted against `dispatchesSkills == true`. GSD's
    /// plugin is `.none`, so nothing it runs ever opens `repo-profile.md` — a
    /// stub that hardcoded `.fail` regardless of `dispatchesSkills` would pass
    /// `profileFailsOnlyForSkillDispatchingMethods` above (it never reaches this
    /// branch) while silently reintroducing the "freezes a GSD board over a
    /// file its skills never read" defect this conditional exists to fix.
    @Test("A method whose skills read nothing warns rather than fails on a missing profile")
    func profileWarnsForMethodsThatDispatchNoSkills() async throws {
        let (path, remove) = try await checkout()
        defer { remove() }

        let gsd = repo(at: path, methodID: "gsd")
        let results = await service().repoChecks(gsd)
        let profile = try #require(results.first { $0.id == "repo.profile" })

        #expect(profile.status == .warn)
    }

    @Test("The packs a global sweep checks always include the default")
    func packsInUseAlwaysIncludesTheDefault() {
        // `globalChecks` runs at launch, before the repository table has been
        // read. An empty list there must not make the plugin check quietly
        // disappear — "nobody looked" wearing a pass is the shape this whole
        // change exists to remove.
        #expect(PreflightService.packsInUse([]).map(\.id) == [MethodCatalog.defaultPackID])

        var unknown = Repo(path: "/x", nameWithOwner: "o/r", displayName: "r")
        unknown.methodID = "no-such-method"
        // An unknown id contributes no pack — it has its own `.fail`, per
        // repository, and there is no plugin name to check.
        #expect(PreflightService.packsInUse([unknown]).map(\.id) == [MethodCatalog.defaultPackID])
    }

    /// ⛔ Without this, `packsInUse` passes as `{ _ in MethodCatalog.builtIn }` —
    /// which answers every question the test above asks and none of the ones the
    /// function exists for.
    @Test("A chosen pack reaches the sweep, and an unchosen one does not")
    func packsInUseCarriesAChosenPack() throws {
        let other = try #require(
            MethodCatalog.builtIn.first { $0.id != MethodCatalog.defaultPackID })
        var chooser = Repo(path: "/x", nameWithOwner: "o/r", displayName: "r")
        chooser.methodID = other.id

        let packs = PreflightService.packsInUse([chooser])
        #expect(packs.contains { $0.id == other.id }, "a chosen pack must be swept")
        #expect(packs.count == 2, "the default plus the chosen one, not the whole catalogue")
        #expect(packs.map(\.id) == packs.map(\.id).sorted(), "order is stable, so rows do not move")
    }

    // MARK: - The key that must not move

    @Test("A seed with no key keeps the exact id it had before methods existed")
    func historicalSeedKeyIsUnchanged() {
        // ⛔ `apply` passes `fix.id` as the card's `idempotencyKey`, and cards
        // seeded by the labels check are already in databases in the field under
        // this exact string. Changing how it is computed would let a second,
        // identical card be created for a finding that had already been seeded.
        let repoID = UUID()
        let fix = CheckFix.seedCard(
            repoID: repoID, title: "Decide this repository's label taxonomy",
            story: UserStory(role: "r", want: "w", benefit: "b"), key: nil
        )
        #expect(fix.id == "seedCard:\(repoID):Decide this repository's label taxonomy")
    }
}
