import Foundation
import Testing

@testable import ElliotModel

/// A repository can say what *it* requires — and "nobody has said" is a third
/// answer, not an empty one (#199, #200).
///
/// `LabelPolicy.default` was a floor Elliot asserted and a repository could not
/// disagree with. Its own doc argues, correctly, for **not parsing**
/// `repo-profile.md` — that file is prose with TODO comments inside the bullets,
/// and a parser would lift `priority: high` out of a comment explaining that no
/// such label exists. That argues against parsing; it never argued for a single
/// global floor.
@Suite("Repository label policy")
struct RepoLabelPolicyTests {

    private func repo(_ policy: [RequiredLabel]?) -> Repo {
        Repo(
            path: "/tmp/elliot", nameWithOwner: "phmatray/Elliot", displayName: "Elliot",
            labelPolicy: policy
        )
    }

    private let house = [
        RequiredLabel(name: "area: engine", color: "111111", description: "the engine"),
    ]

    @Test("A repository that has said nothing gets Elliot's floor, named as Elliot's")
    func unansweredFallsBackToTheFloor() {
        let resolved = LabelPolicy.resolved(for: repo(nil))
        #expect(resolved.required == LabelPolicy.default)
        #expect(resolved.source == .elliotFloor)
        #expect(resolved.isUndecided)
        #expect(resolved.whose == "Elliot's skills apply")
    }

    @Test("A repository that declared its own set gets it, named as its own")
    func declaredWins() {
        let resolved = LabelPolicy.resolved(for: repo(house))
        #expect(resolved.required == house)
        #expect(resolved.source == .repository)
        #expect(!resolved.isUndecided)
        #expect(resolved.whose == "this repository requires")
    }

    /// Criterion 6 of #199, and the hinge of #200's criterion 4.
    ///
    /// ⛔ `isUndecided` is **not** `required.isEmpty`. A repository that declared
    /// an empty set has decided — it means *check nothing* — and asking again
    /// would nag it for an answer it already gave. This is the same three-valued
    /// distinction `RepositoryLabels` is built on: `.known([])` is a finding,
    /// `.unavailable` is the absence of one.
    @Test("Declaring an empty set is a decision, not the absence of one")
    func emptyIsADecision() {
        let resolved = LabelPolicy.resolved(for: repo([]))
        #expect(resolved.required.isEmpty)
        #expect(resolved.source == .repository)
        #expect(!resolved.isUndecided, "an empty policy read as 'nobody has chosen'")
    }

    @Test("The two sources say different things, so a pass cannot be misread")
    func theTwoSourcesReadDifferently() {
        #expect(
            LabelPolicy.Resolved(required: [], source: .elliotFloor).whose
                != LabelPolicy.Resolved(required: [], source: .repository).whose
        )
    }

    /// The default is unchanged, and this is the fact #200 turns on: every one of
    /// these is already present on `phmatray/Elliot`, so the check passes there
    /// and — until #200 — offered nothing at all.
    @Test("Elliot's floor is still GitHub's four stock labels")
    func theFloorIsUnchanged() {
        #expect(LabelPolicy.default.map(\.name) == ["bug", "enhancement", "documentation", "question"])
    }
}
