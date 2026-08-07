import ElliotModel
import ElliotProcess
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
            repoID: repoID,
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

        // `warn`, never `fail`: `isBlocking` treats any `.fail` as "cards cannot
        // be dragged", and a missing `documentation` label must not freeze a
        // board.
        #expect(check.status == .warn)
        // Each one named. "Some labels are missing" sends the reader to GitHub
        // to work out which.
        #expect(check.detail.contains("documentation"))
        #expect(check.detail.contains("question"))
        // And not the ones that are there.
        #expect(!check.detail.contains("enhancement"))

        #expect(check.fixes.count == 2)
        if case .createLabels(_, let labels) = check.fixes[0] {
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
        if case .createLabels(_, let labels) = check.fixes[0] {
            #expect(labels.count == LabelPolicy.default.count)
        } else {
            Issue.record("expected a create-labels fix")
        }
    }

    @Test("A missing label never blocks a board")
    func missingLabelsAreNotBlocking() async {
        let check = await service().labelsCheck(repo, required: LabelPolicy.default)
        #expect(!PreflightService.isBlocking([check]))
    }

    @Test("Fixes are identifiable and hashable, so a view can list them")
    func fixesAreListable() {
        let repoID = UUID()
        let a = CheckFix.createLabels(repoID: repoID, labels: [])
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
}
