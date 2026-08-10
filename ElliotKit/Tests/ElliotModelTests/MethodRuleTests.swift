import Foundation
import Testing

@testable import ElliotModel

/// The repair of finding I2: the method decides *inside* the rule engine.
///
/// Wave 1 first shipped this refusal as a `throw` in `BoardService.makeRun`,
/// downstream of `evaluateMove`. That broke the invariant the whole board rests
/// on — *"`rankNextSteps` decides by calling `evaluateMove`, so the board
/// predicts its own behaviour instead of holding a second copy of the rules"* —
/// because `MoveContext` carried no method. A BMAD repository, which ships no
/// steps by design, therefore read **ready** in `board_next` and on the drop
/// caption, and then threw at commit.
///
/// It failed closed, so nothing ever spawned. What it produced was a board that
/// lied about itself, and `AppModel.preview`'s doc comment had to be rewritten
/// to admit it. These tests are the gate: remove either guard from
/// `evaluateMove` and they go red.
@Suite("The method decides inside the rule engine")
struct MethodRuleTests {

    /// ⚠️ `filed` defaults to **false**, and that is not a stylistic choice.
    ///
    /// `evaluateMove` short-circuits Backlog → To Do to `.noAction` for a card
    /// that already carries an issue number — *"already filed, moving it again
    /// must not open a second issue"* — **before** any method guard runs. A
    /// fixture that set one made every create-issue assertion here fail for that
    /// reason instead of the one under test, which is how the first draft of
    /// this suite reported four red tests that said nothing about the method.
    private func card(_ column: Column, filed: Bool = false) -> Card {
        let fixed = Date(timeIntervalSince1970: 1_754_600_000)
        var card = Card(
            repoID: UUID(),
            title: "Give the archive a search field",
            body: "",
            story: UserStory(
                role: "someone reading finished work",
                want: "to search it",
                benefit: "I can find what shipped"
            ),
            column: column,
            columnEnteredAt: fixed,
            createdAt: fixed,
            updatedAt: fixed
        )
        if filed {
            card.issueNumber = 162
            card.prNumber = 226
        }
        return card
    }

    private func pack(_ id: String) throws -> MethodPack {
        try #require(MethodCatalog.builtIn.first { $0.id == id })
    }

    // MARK: - A pack that declares no step for the transition

    @Test("A stepless pack refuses the move rather than being predicted as ready")
    func steplessPackBlocks() throws {
        let stepless = try #require(MethodCatalog.builtIn.first { $0.steps.isEmpty })
        let outcome = evaluateMove(
            from: .backlog, to: .todo, card: card(.backlog),
            context: MoveContext(
                repoPreflight: .passing, method: .chosen(stepless),
                requiresVerifiedGreen: false, prVerdict: nil
            )
        )
        guard case .blocked(.methodHasNoStep(let method, let kind)) = outcome else {
            Issue.record("expected methodHasNoStep, got \(outcome)")
            return
        }
        #expect(method == stepless.displayName)
        #expect(kind == SkillKind.createIssue.skillName)
    }

    /// The heart of I2. `rankNextSteps` is what `board_next` answers with and
    /// what the drop caption previews; before the repair it said `isReady` for a
    /// card whose only forward move threw.
    @Test("board_next does not offer a card whose method has no step for it")
    func rankingAgreesWithTheRefusal() throws {
        let stepless = try #require(MethodCatalog.builtIn.first { $0.steps.isEmpty })
        let candidate = NextCandidate(
            card: card(.backlog),
            repoName: "phmatray/elliot",
            context: MoveContext(
                repoPreflight: .passing, method: .chosen(stepless),
                requiresVerifiedGreen: false, prVerdict: nil
            )
        )
        let step = try #require(rankNextSteps([candidate]).first)
        #expect(!step.isReady, "the board offered a move its own commit would refuse")
        #expect(step.triggers == nil)
        #expect(step.block == .methodHasNoStep(
            method: stepless.displayName, kind: SkillKind.createIssue.skillName))
    }

    /// GSD declares `create-issue` and nothing else (amendment A3), so it is the
    /// pack that proves the guard is per-transition rather than per-repository.
    @Test("A pack with some steps is offered exactly where it has one")
    func partialPackIsOfferedOnlyWhereItCan() throws {
        let gsd = try pack("gsd")
        try #require(gsd.steps[.createIssue] != nil)
        try #require(gsd.steps[.implementIssue] == nil)

        let filing = evaluateMove(
            from: .backlog, to: .todo, card: card(.backlog),
            context: MoveContext(
                repoPreflight: .passing, method: .chosen(gsd),
                requiresVerifiedGreen: false, prVerdict: nil
            )
        )
        guard case .action(.createIssue) = filing else {
            Issue.record("GSD declares create-issue and must be offered it, got \(filing)")
            return
        }

        let implementing = evaluateMove(
            from: .todo, to: .inProgress, card: card(.todo, filed: true),
            context: MoveContext(
                repoPreflight: .passing, method: .chosen(gsd),
                requiresVerifiedGreen: false, prVerdict: nil
            )
        )
        #expect(implementing == .blocked(.methodHasNoStep(
            method: gsd.displayName, kind: SkillKind.implementIssue.skillName)))
    }

    // MARK: - A method this build does not know

    /// Unlike a missing step, this one blocks *every* transition: we do not know
    /// what any of them would run. Placed beside `repoBlocked` for that reason.
    @Test("An unknown method blocks every transition, not only the ones that run something")
    func unknownMethodBlocksEverything() {
        let context = MoveContext(
            repoPreflight: .passing, method: .unknown("gsd-v2"),
            requiresVerifiedGreen: false, prVerdict: nil
        )
        for (from, to) in [
            (Column.backlog, Column.todo),
            (Column.todo, Column.inProgress),
            (Column.inProgress, Column.inReview),
            (Column.inReview, Column.done),
        ] {
            // Filed, so the two later transitions have the numbers they need and
            // this test measures the method guard rather than a missing field.
            // Backlog → To Do would short-circuit to `.noAction` for a filed
            // card — but the unknown-method guard sits *above* the transition
            // switch, which is exactly the claim under test here.
            let outcome = evaluateMove(
                from: from, to: to, card: card(from, filed: true), context: context)
            #expect(
                outcome == .blocked(.unknownMethod("gsd-v2")),
                "\(from) → \(to) was not refused: \(outcome)"
            )
        }
    }

    // MARK: - The repository that never chose

    /// The wave's own refactor claim, at the rule-engine layer: "never chosen"
    /// is what every board did before this branch and what every existing test
    /// in this target was written against, and it must still mean that.
    ///
    /// ⚠️ This used to make the point by **omitting** the argument, and that is
    /// exactly the spelling that had to go: `method` lost its default when a
    /// review measured two of its three production sites unpinned. The claim is
    /// about the *value* `.unset` and survives intact; only the shorthand died.
    @Test("A repository that never chose still gets the moves it always got")
    func unsetIsUnchanged() {
        let defaulted = evaluateMove(
            from: .backlog, to: .todo, card: card(.backlog),
            context: MoveContext(
                repoPreflight: .passing, method: MethodCatalog.resolve(nil),
                requiresVerifiedGreen: false, prVerdict: nil
            )
        )
        guard case .action(.createIssue) = defaulted else {
            Issue.record("a repository with no method chosen lost its create-issue, got \(defaulted)")
            return
        }
    }

    // MARK: - The assembly step

    /// The half of I2 that no test held, found by an independent review after
    /// the repair had been written and merged into a branch review.
    ///
    /// `evaluateMove` and `rankNextSteps` were both pinned; the **assembly**
    /// between them was not. `nextCandidates` reads the method off the `Repo`
    /// row, and deleting that one argument left the whole suite green at
    /// 1840/1840 — restoring finding I2 on the exact path the repair names,
    /// silently. `MoveContext.method` has lost its default since, so the
    /// omission no longer compiles; this covers the other half, a site that
    /// passes *something* but not the repository's own answer.
    ///
    /// ⚠️ `OfflineParityTests` cannot see this. The live path and the offline
    /// path both call this one function, so the two halves would agree with each
    /// other and both be wrong — which is the one regression a parity test is
    /// structurally unable to catch.
    @Test("nextCandidates carries the method, so board_next refuses too")
    func nextCandidatesCarriesTheMethod() throws {
        let stepless = try #require(
            MethodCatalog.builtIn.first { $0.steps.isEmpty },
            "the catalogue no longer ships a stepless pack — this test needs one")
        var repo = Repo(
            path: "/tmp/stepless",
            nameWithOwner: "phmatray/stepless",
            displayName: "stepless",
            methodID: stepless.id
        )
        repo.preflight = .passing

        var subject = card(.backlog)
        subject.repoID = repo.id

        let steps = rankNextSteps(
            nextCandidates(cards: [subject], repos: [repo], activeRunIDs: [:])
        )
        let step = try #require(steps.first)

        #expect(!step.isReady, "the board offered a move its own commit would refuse")
        #expect(step.triggers == nil)
        #expect(step.block == .methodHasNoStep(
            method: stepless.displayName, kind: SkillKind.createIssue.skillName))
    }

    // MARK: - Ordering

    /// A repository Preflight refused is refused for *that* reason, whatever its
    /// method — otherwise the sentence on screen would name the wrong remedy.
    @Test("A blocked repository is still reported as blocked, not as an unknown method")
    func preflightOutranksTheMethod() {
        let outcome = evaluateMove(
            from: .backlog, to: .todo, card: card(.backlog),
            context: MoveContext(
                repoPreflight: .failing, method: .unknown("gsd-v2"),
                requiresVerifiedGreen: false, prVerdict: nil
            )
        )
        #expect(outcome == .blocked(.repoBlocked))
    }
}
