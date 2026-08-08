import Foundation
import Testing

@testable import ElliotModel

private let then = Date(timeIntervalSince1970: 1_700_000_000)
private let probe = Provenance(command: "gh api", observedAt: then)

@Suite("The five predicates")
struct StandardPredicatesTests {

    private func repo(
        _ name: String = "phmatray/Foo", visibility: String = "PUBLIC",
        lang: String = "C#", branch: String = "dev"
    ) -> GHRepoSummary {
        GHRepoSummary(
            nameWithOwner: name, visibility: visibility,
            defaultBranchRef: .init(name: branch),
            primaryLanguage: GHLanguage(name: lang))
    }

    private func measurement(
        tree: Reading<RepoTree> = .observed(RepoTree(paths: [], truncated: false), probe),
        workflows: Reading<[String: String]> = .observed([:], probe),
        topics: Reading<[String]> = .observed([], probe),
        licence: Reading<String?> = .observed(nil, probe)
    ) -> RepoMeasurement {
        RepoMeasurement(
            tree: tree, workflows: workflows, dependencyConfig: .observed(nil, probe),
            topics: topics, licenceSPDX: licence)
    }

    // `StandardPredicates.evaluate` returns a `StandardOutcome` (verdict +
    // evidence + provenances) — the widening `StandardsEngine.swift` already
    // documents. This helper takes just the verdict field for the tests below
    // that don't care about citations or provenance.
    private func verdict(_ s: Standard, _ r: GHRepoSummary, _ m: RepoMeasurement) -> StandardVerdict {
        StandardPredicates.evaluate(s, repo: r, measurement: m, now: then, freshness: .default).verdict
    }

    // MARK: editorconfig

    @Test("An .editorconfig at the root is compliant")
    func editorconfigPresent() {
        let m = measurement(tree: .observed(RepoTree(paths: [".editorconfig"], truncated: false), probe))
        guard case .compliant = verdict(.editorconfig, repo(), m) else {
            Issue.record("expected compliant"); return
        }
    }

    /// Only the root counts: `root = true` lives at the root, and a nested file
    /// does not configure the repository.
    @Test("An .editorconfig in a subdirectory does not count")
    func editorconfigNested() {
        let m = measurement(tree: .observed(RepoTree(paths: ["src/.editorconfig"], truncated: false), probe))
        guard case .violating = verdict(.editorconfig, repo(), m) else {
            Issue.record("expected violating"); return
        }
    }

    /// The truncation trap: absence from an incomplete list is not absence.
    @Test("A truncated tree cannot prove an .editorconfig is missing")
    func editorconfigTruncated() {
        let m = measurement(tree: .observed(RepoTree(paths: ["README.md"], truncated: true), probe))
        guard case .unmeasured(.treeTruncated) = verdict(.editorconfig, repo(), m) else {
            Issue.record("expected unmeasured"); return
        }
    }

    // MARK: dependencyAutomation

    @Test("Any of the four Renovate paths counts")
    func renovateAnyPath() {
        for path in ["renovate.json", ".github/renovate.json", ".renovaterc.json", ".renovaterc"] {
            let m = measurement(tree: .observed(RepoTree(paths: [path], truncated: false), probe))
            guard case .compliant = verdict(.dependencyAutomation, repo(), m) else {
                Issue.record("\(path) should count"); return
            }
        }
    }

    @Test("Dependabot counts as dependency automation")
    func dependabotCounts() {
        let m = measurement(tree: .observed(
            RepoTree(paths: [".github/dependabot.yml"], truncated: false), probe))
        guard case .compliant = verdict(.dependencyAutomation, repo(), m) else {
            Issue.record("expected compliant"); return
        }
    }

    // MARK: ciJudgeable

    @Test("A workflow triggering on any pull request is judgeable")
    func ciUnfiltered() {
        let m = measurement(workflows: .observed(
            [".github/workflows/ci.yml": "on:\n  pull_request:\njobs: {}\n"], probe))
        guard case .compliant = verdict(.ciJudgeable, repo(), m) else {
            Issue.record("expected compliant"); return
        }
    }

    /// The exact pattern the portfolio is full of: filtered to `main` while the
    /// default branch is `dev`, so every check reports `skipped`.
    @Test("A filter naming another branch leaves the repository unjudgeable")
    func ciFilteredToWrongBranch() {
        let m = measurement(workflows: .observed(
            [".github/workflows/ci.yml": "on:\n  pull_request:\n    branches: [main]\njobs: {}\n"],
            probe))
        guard case .violating = verdict(.ciJudgeable, repo(branch: "dev"), m) else {
            Issue.record("expected violating"); return
        }
    }

    @Test("A filter matching the default branch is fine")
    func ciFilteredToDefault() {
        let m = measurement(workflows: .observed(
            [".github/workflows/ci.yml": "on:\n  pull_request:\n    branches: [dev]\njobs: {}\n"],
            probe))
        guard case .compliant = verdict(.ciJudgeable, repo(branch: "dev"), m) else {
            Issue.record("expected compliant"); return
        }
    }

    /// One badly filtered workflow among several correct ones is not a failure.
    /// This is the criterion that makes the real count 9 rather than ~30.
    @Test("One live workflow is enough, however many dead ones there are")
    func ciOneLiveIsEnough() {
        let m = measurement(workflows: .observed([
            ".github/workflows/deploy.yml": "on:\n  push:\n    branches: [main]\njobs: {}\n",
            ".github/workflows/ci.yml": "on:\n  pull_request:\njobs: {}\n",
        ], probe))
        guard case .compliant = verdict(.ciJudgeable, repo(), m) else {
            Issue.record("expected compliant"); return
        }
    }

    @Test("The inline list form is understood")
    func ciInlineForm() {
        let m = measurement(workflows: .observed(
            [".github/workflows/ci.yml": "on: [push, pull_request]\njobs: {}\n"], probe))
        guard case .compliant = verdict(.ciJudgeable, repo(), m) else {
            Issue.record("expected compliant"); return
        }
    }

    // MARK: topics

    /// The arbitration: the documented rule, not any of the four implementations.
    @Test("dotnet and csharp alone are not a family topic")
    func topicsUbiquitousOnly() {
        let m = measurement(topics: .observed(["dotnet", "csharp"], probe))
        guard case .violating = verdict(.topics, repo(), m) else {
            Issue.record("expected violating"); return
        }
    }

    @Test("One topic beyond the ubiquitous pair is enough")
    func topicsFamilyPresent() {
        let m = measurement(topics: .observed(["dotnet", "blazor"], probe))
        guard case .compliant = verdict(.topics, repo(), m) else {
            Issue.record("expected compliant"); return
        }
    }

    // MARK: licence

    @Test("Personal public code expects MIT")
    func licenceMIT() {
        let m = measurement(licence: .observed("MIT", probe))
        guard case .compliant = verdict(.licence, repo(), m) else {
            Issue.record("expected compliant"); return
        }
    }

    /// The one axis where carrying a licence is the violation. A permissive
    /// licence on a commercial product gives the product away, and it is not
    /// retractable from anyone who already has it.
    @Test("A private company repository expects no licence at all")
    func licenceCompanyPrivateExpectsNone() {
        let company = repo("Atypical-Consulting/Product", visibility: "PRIVATE")
        guard case .compliant = verdict(.licence, company, measurement(licence: .observed(nil, probe)))
        else { Issue.record("expected compliant"); return }
        guard case .violating = verdict(.licence, company, measurement(licence: .observed("MIT", probe)))
        else { Issue.record("MIT on a product must violate"); return }
    }

    /// Keyed on the language, the way the code does — not on a `latex` topic,
    /// the way the prose reads. A topic-keyed port gives CC-BY-4.0 to anything
    /// tagged latex whatever it contains.
    @Test("A TeX paper expects CC-BY-4.0")
    func licenceLatexPaper() {
        let paper = repo("phmatray/fire-book", lang: "TeX")
        guard case .compliant = verdict(.licence, paper, measurement(licence: .observed("CC-BY-4.0", probe)))
        else { Issue.record("expected compliant"); return }
    }

    // MARK: evidence

    /// A violation must cite what was looked for — but only when the axis
    /// actually looked at a path. `topics` and `licence` have none to give;
    /// inventing one would be a fabricated citation.
    @Test("A violation carries its evidence; topics has none to give")
    func violationEvidence() {
        let editorconfigOutcome = StandardPredicates.evaluate(
            .editorconfig, repo: repo(), measurement: measurement(), now: then, freshness: .default)
        #expect(editorconfigOutcome.evidence == [Evidence(path: ".editorconfig", exists: false)])

        let topicsOutcome = StandardPredicates.evaluate(
            .topics, repo: repo(), measurement: measurement(topics: .observed(["dotnet"], probe)),
            now: then, freshness: .default)
        #expect(topicsOutcome.evidence.isEmpty)
    }

    // MARK: provenance

    /// `observationLag` reduces over this list, so a verdict resting on a
    /// 20-hour-old tree must not report the age of the freshest thing nearby.
    @Test("A verdict reports the age of what it actually read")
    func reportsTheReadItPerformed() {
        let old = Provenance(command: "gh api …/git/trees", observedAt: then.addingTimeInterval(-20 * 3600))
        let m = measurement(tree: .observed(RepoTree(paths: [], truncated: false), old))
        let outcome = StandardPredicates.evaluate(
            .editorconfig, repo: repo(), measurement: m, now: then, freshness: .default)
        #expect(outcome.provenances == [old])
    }

    /// The topics axis never opens the tree, so it must not claim to have.
    @Test("An axis claims only the readings it opened")
    func claimsOnlyWhatItOpened() {
        let treeProbe = Provenance(command: "gh api …/git/trees", observedAt: then)
        let topicProbe = Provenance(command: "gh api …/topics", observedAt: then)
        let m = RepoMeasurement(
            tree: .observed(RepoTree(paths: [], truncated: false), treeProbe),
            workflows: .observed([:], treeProbe),
            dependencyConfig: .observed(nil, treeProbe),
            topics: .observed(["blazor"], topicProbe),
            licenceSPDX: .observed(nil, treeProbe))
        let outcome = StandardPredicates.evaluate(
            .topics, repo: repo(), measurement: m, now: then, freshness: .default)
        #expect(outcome.provenances == [topicProbe])
    }

    /// Workflows that exist and whose `on:` block this scanner cannot locate.
    /// "I could not read it" is not "it has no trigger": read as a violation it
    /// would file a card, and on this board a card is an agent sent at a
    /// repository whose CI may be perfectly fine. It must also name the files —
    /// the fix is a better scanner or a corrected workflow, and neither is
    /// actionable without knowing which file to open.
    @Test("Workflows nobody can parse are unmeasured, and they are named")
    func unparseableWorkflowsAreUnmeasuredAndNamed() {
        let m = measurement(workflows: .observed([
            ".github/workflows/ci.yml": "jobs:\n  build:\n    runs-on: ubuntu-latest\n",
            ".github/workflows/release.yml": "# no trigger block at all\n",
        ], probe))
        let outcome = StandardPredicates.evaluate(
            .ciJudgeable, repo: repo(), measurement: m, now: then, freshness: .default)

        guard case .unmeasured(.unreadableContent(let detail)) = outcome.verdict else {
            Issue.record("got \(outcome.verdict)"); return
        }
        #expect(detail.contains(".github/workflows/ci.yml"))
        #expect(detail.contains(".github/workflows/release.yml"))
        #expect(outcome.evidence.map(\.path).sorted()
                == [".github/workflows/ci.yml", ".github/workflows/release.yml"])
    }
}
