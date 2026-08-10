import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine

/// The taxonomy conversation must be reachable on the repositories that need it
/// (#200), and recordable so it is not asked twice.
///
/// #172 shipped two fixes on the labels check, and attached both to the `.warn`
/// branch: the `guard missing.isEmpty else { return … .pass … }` early return
/// carried **no fixes at all**. The floor is GitHub's four stock labels,
/// deliberately chosen as something a fresh repository already satisfies — so on
/// a repository that has them, the check passed and the fix designed to start
/// the taxonomy conversation was never offered.
///
/// Measured on `phmatray/Elliot` while writing this: `gh label list` returns
/// `bug documentation duplicate enhancement good first issue help wanted invalid
/// question wontfix`, so all four floor labels are present. ⚠️ #172's own body
/// claimed *"This repository would fail its own check"*; it does not, and it
/// never did — the claim was not copied into any committed file, so this test is
/// where the correction lives.
@Suite("The taxonomy question is reachable, and answerable")
struct LabelTaxonomyReachTests {

    private struct Paths {
        static var repoRoot: URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        }
        static var fakeGH: String { repoRoot.appendingPathComponent("Scripts/fake-gh.sh").path }
        static func fixture(_ name: String) -> String {
            repoRoot.appendingPathComponent("Fixtures/gh/\(name)").path
        }
    }

    private func service() -> PreflightService {
        PreflightService(
            environment: LoginShellEnvironment(variables: [:], capturedVia: "test"),
            config: ToolConfig(
                claudePath: "/usr/bin/false", ghPath: Paths.fakeGH, gitPath: "/usr/bin/false",
                environment: ["FAKE_GH_LABELS": Paths.fixture("labels.json")]
            )
        )
    }

    /// The fixture carries `bug` and `enhancement`, so a policy naming exactly
    /// those passes — which is the state `phmatray/Elliot` is really in.
    private let satisfied = [
        RequiredLabel(name: "bug", color: "d73a4a", description: "x"),
        RequiredLabel(name: "enhancement", color: "a2eeef", description: "y"),
    ]

    private func repo(_ policy: [RequiredLabel]?) -> Repo {
        Repo(
            path: "/tmp/elliot", nameWithOwner: "phmatray/Elliot", displayName: "Elliot",
            labelPolicy: policy
        )
    }

    @Test("A passing check on an unasked repository still offers the conversation")
    func passingStillOffersTheConversation() async {
        let check = await service().labelsCheck(
            repo(nil), policy: LabelPolicy.Resolved(required: satisfied, source: .elliotFloor))

        #expect(check.status == .pass)
        #expect(check.fixes.count == 2, "a passing row offered nothing to press")
        #expect(check.fixes.contains { if case .adoptLabelPolicy = $0 { true } else { false } })
        #expect(check.fixes.contains { if case .seedCard = $0 { true } else { false } })
        // Criterion 5: the pass must not read as endorsement of a taxonomy
        // nobody chose.
        #expect(check.detail.contains("nobody has said what this repository should require"))
    }

    @Test("A repository that has answered is not asked again")
    func answeredIsNotNagged() async {
        let check = await service().labelsCheck(
            repo(satisfied), policy: LabelPolicy.Resolved(required: satisfied, source: .repository))

        #expect(check.status == .pass)
        #expect(check.fixes.isEmpty)
        #expect(check.detail == "All 2 labels this repository requires are present.")
    }

    /// A repository that chose to require nothing has still chosen.
    @Test("An empty declared policy passes, and is not asked again either")
    func anEmptyPolicyIsAnAnswer() async {
        let check = await service().labelsCheck(
            repo([]), policy: LabelPolicy.resolved(for: repo([])))

        #expect(check.status == .pass)
        #expect(check.fixes.isEmpty)
    }

    /// ⛔ Keeping the floor is **not** offered while labels are missing: the row
    /// is already telling the reader what is absent, and adopting a policy the
    /// repository does not meet records a decision while leaving the warning up.
    @Test("A warning row keeps its two fixes and does not grow a third")
    func aWarningDoesNotOfferToAdopt() async {
        let check = await service().labelsCheck(
            repo(nil),
            policy: LabelPolicy.Resolved(required: LabelPolicy.default, source: .elliotFloor))

        #expect(check.status == .warn)
        #expect(check.fixes.count == 2)
        #expect(!check.fixes.contains { if case .adoptLabelPolicy = $0 { true } else { false } })
    }

    /// The writer. Until this existed the column had readers and nothing that
    /// assigned it — the shape #333 found one field over.
    @Test("Keeping the floor records it on the repository, and stops the asking")
    func adoptingWritesThePolicy() async throws {
        let store = try BoardStore.inMemory()
        let subject = repo(nil)
        try await store.saveRepo(subject)
        let scheduler = RunScheduler(
            store: store,
            toolConfig: ToolConfig(
                claudePath: "/usr/bin/false", ghPath: "/usr/bin/false", gitPath: "/usr/bin/false",
                environment: [:]),
            verifier: Verifier(gh: .init(config: ToolConfig(
                claudePath: "/usr/bin/false", ghPath: "/usr/bin/false", gitPath: "/usr/bin/false",
                environment: [:])))
        )
        let board = BoardService(store: store, launcher: scheduler)

        let outcome = await service().apply(
            .adoptLabelPolicy(repoID: subject.id, labels: satisfied),
            repo: subject, board: board, store: store)

        #expect(outcome.succeeded)
        let after = try #require(try await store.repo(id: subject.id))
        #expect(after.labelPolicy == satisfied)
        #expect(!LabelPolicy.resolved(for: after).isUndecided)
        // And the check on that repository now offers nothing.
        let check = await service().labelsCheck(after)
        #expect(check.fixes.isEmpty)
    }

    /// A fix that cannot reach a store says so rather than reporting success —
    /// the failure this whole screen is being taught to avoid.
    @Test("Keeping the floor with no store refuses out loud")
    func adoptingWithoutAStoreRefuses() async throws {
        let store = try BoardStore.inMemory()
        let scheduler = RunScheduler(
            store: store,
            toolConfig: ToolConfig(
                claudePath: "/usr/bin/false", ghPath: "/usr/bin/false", gitPath: "/usr/bin/false",
                environment: [:]),
            verifier: Verifier(gh: .init(config: ToolConfig(
                claudePath: "/usr/bin/false", ghPath: "/usr/bin/false", gitPath: "/usr/bin/false",
                environment: [:])))
        )
        let board = BoardService(store: store, launcher: scheduler)

        let outcome = await service().apply(
            .adoptLabelPolicy(repoID: repo(nil).id, labels: satisfied),
            repo: repo(nil), board: board, store: nil)

        #expect(!outcome.succeeded)
        #expect(!outcome.detail.isEmpty)
    }
}
