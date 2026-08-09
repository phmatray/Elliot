import Foundation
import Testing

@testable import ElliotModel

private let then = Date(timeIntervalSince1970: 1_700_000_000)
private let probe = Provenance(command: "gh api", observedAt: then)

@Suite("The card a violation deserves")
struct StandardCardSeedTests {

    private func finding(_ v: StandardVerdict) -> StandardFinding {
        StandardFinding(
            id: "phmatray/Foo#editorconfig", nameWithOwner: "phmatray/Foo",
            standard: .editorconfig, verdict: v,
            evidence: [Evidence(path: ".editorconfig", line: nil, exists: false)],
            provenances: [probe], assessedAt: then)
    }

    private let repo = GHRepoSummary(
        nameWithOwner: "phmatray/Foo", visibility: "PUBLIC",
        defaultBranchRef: .init(name: "dev"), primaryLanguage: GHLanguage(name: "C#"))

    @Test("Only a violation produces a seed")
    func onlyViolationSeeds() {
        #expect(StandardsEngine.cardSeed(
            for: finding(.compliant(detail: "present")), repo: repo, epoch: then) == nil)
        #expect(StandardsEngine.cardSeed(
            for: finding(.unmeasured(.rateLimited)), repo: repo, epoch: then) == nil)
        #expect(StandardsEngine.cardSeed(
            for: finding(.notApplicable(.fork)), repo: repo, epoch: then) == nil)
        #expect(StandardsEngine.cardSeed(
            for: finding(.exempt(Exemption(
                standard: .editorconfig, reason: "hand-maintained", grantedBy: "philippe",
                grantedAt: then, expires: nil, evidence: nil))),
            repo: repo, epoch: then) == nil)
    }

    @Test("A violation produces a complete user story")
    func violationSeedsAStory() throws {
        let v = Violation(
            summary: "No .editorconfig at the root", expected: "an .editorconfig at the root",
            actual: "absent", fixHint: nil)
        let seed = try #require(
            StandardsEngine.cardSeed(for: finding(.violating(v)), repo: repo, epoch: then))
        #expect(seed.story.isComplete)
        #expect(!seed.story.acceptanceCriteria.isEmpty)
        // The rubric, the expected/actual pair and the command are all on the
        // card, so the agent that picks it up does not have to re-derive them.
        #expect(seed.body.contains("gh api"))
        #expect(seed.body.contains("an .editorconfig at the root"))
        // A criterion identical to the wish verifies nothing: the first
        // criterion must be the expectation tied to the command that checks
        // it, not the `want` repeated back.
        #expect(seed.story.acceptanceCriteria.first != seed.story.want)
        #expect(seed.story.acceptanceCriteria.first?.contains("gh api") == true)
    }

    /// The same sweep must not file twice; a LATER recurrence must be filable.
    /// A permanent key means an expired exemption can never produce a card
    /// again, because `createCard` returns the archived original.
    @Test("The key is stable within an epoch and changes across them")
    func keyCarriesTheEpoch() throws {
        let v = Violation(summary: "s", expected: "e", actual: "a", fixHint: nil)
        let a = try #require(StandardsEngine.cardSeed(
            for: finding(.violating(v)), repo: repo, epoch: then))
        let b = try #require(StandardsEngine.cardSeed(
            for: finding(.violating(v)), repo: repo, epoch: then))
        let later = try #require(StandardsEngine.cardSeed(
            for: finding(.violating(v)), repo: repo, epoch: then.addingTimeInterval(86_400)))
        #expect(a.idempotencyKey == b.idempotencyKey)
        #expect(a.idempotencyKey != later.idempotencyKey)
        #expect(a.idempotencyKey.hasPrefix("standard:phmatray/Foo:editorconfig:"))
    }
}
