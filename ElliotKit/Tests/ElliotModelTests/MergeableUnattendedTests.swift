import Foundation
import Testing

@testable import ElliotModel

private let readAt = Date(timeIntervalSince1970: 1_700_000_000)

/// A resolved reading with every facet stated.
///
/// Built directly rather than through `PRStatus.resolved`, on purpose: the
/// precedence that derives `sign` from the three facets is `PRStatus.sign`'s and
/// is tested there. What is under test here is the predicate, so its inputs are
/// given rather than computed — including combinations `sign` would never
/// produce, because a predicate that is only ever fed consistent inputs is a
/// predicate nobody has actually cornered.
private func reading(
    ci: CIState = .passing(["build-and-test"]),
    merge: MergeState = .clean,
    review: ReviewState = .approved,
    isStale: Bool = false,
    sign: PRSign? = nil
) -> ResolvedPRStatus {
    ResolvedPRStatus(
        ci: ci, merge: merge, review: review,
        checkedAt: readAt, headRefOid: "a1b2c3d4e5f6", isStale: isStale, sign: sign)
}

private func check(_ name: String) -> GHMergeStatus.StatusCheck {
    GHMergeStatus.StatusCheck(name: name, conclusion: "SUCCESS", status: "COMPLETED")
}

/// The same reading, **derived** rather than stated: a real `PRStatus` put
/// through `PRStatus.resolved(now:currentHeadOid:)`.
///
/// Both holes below are holes *in `PRStatus.sign`*, so a fixture that sets
/// `sign` by hand cannot reproduce either of them — `#expect(x.sign == nil)`
/// would only read back what the helper above was told, and would go on passing
/// on the day `sign` starts catching `unstable`. These two go through the real
/// derivation, which is what makes the `sign == nil` line a measurement instead
/// of a restatement of its own input.
private func derived(
    checks: [GHMergeStatus.StatusCheck] = [check("build-and-test")],
    mergeStateStatus: String = "CLEAN",
    mergeable: String = "MERGEABLE",
    reviewDecision: String = "APPROVED"
) -> ResolvedPRStatus {
    PRStatus(
        repoID: UUID(), prNumber: 7, headRefOid: "a1b2c3d4e5f6", checkedAt: readAt,
        rawMergeStateStatus: mergeStateStatus, rawMergeable: mergeable,
        rawReviewDecision: reviewDecision, checks: checks
    ).resolved(now: readAt, currentHeadOid: "a1b2c3d4e5f6")
}

/// What an agent with nobody behind it is allowed to merge to a default branch.
///
/// Every test here is a **refusal** except the first, and that is the shape of
/// the feature: the obvious predicate — `sign == nil` — was measured too weak in
/// two separate ways, and each of those two ways has a test below whose failure
/// would restore it.
@Suite("Mergeable unattended")
struct MergeableUnattendedTests {

    @Test("A fresh, clean, reviewed pull request with a real build is mergeable")
    func theOneGreen() {
        #expect(reading().isMergeableUnattended)
    }

    @Test("A sign of any kind refuses, whatever else is true")
    func anySignRefuses() {
        let signs: [PRSign] = [
            .conflict, .checksFailing(count: 1), .changesRequested, .reviewRequired,
            .mergeBlocked, .checksRunning, .noBuild, .unknown,
        ]
        for sign in signs {
            #expect(!reading(sign: sign).isMergeableUnattended, "\(sign.code) was accepted")
        }
    }

    @Test("A stale reading refuses even with nothing to report")
    func stalenessRefuses() {
        // `sign` is nil here on purpose. A reading that aged out or is about a
        // commit nobody is reviewing any more has nothing to report *because it
        // reports nothing at all*, and reading that as an all-clear is the
        // difference between "I know it is fine" and "I do not know".
        #expect(!reading(isStale: true).isMergeableUnattended)
    }

    @Test("UNSTABLE is not clean, and sign == nil does not catch it")
    func unstableRefuses() {
        // The first measured hole in `sign == nil`: `PRStatus.sign` blocks only
        // `.conflict` and `.behind`/`.blocked`, so `MergeState.unstable` reaches
        // `return nil`. The panel paints that same state in `Palette.attention`
        // and calls it "mergeable, not every check is green".
        //
        // `derived`, not `reading`: the hole is in `sign`'s own precedence, so a
        // hand-set `sign` would assert nothing but itself.
        let unstable = derived(mergeStateStatus: "UNSTABLE")
        #expect(unstable.merge == .unstable, "the fixture no longer reaches UNSTABLE")
        #expect(unstable.sign == nil, "the fixture no longer reproduces the hole")
        #expect(!unstable.isMergeableUnattended)
    }

    @Test("A green that is only an analyser refuses")
    func analyserOnlyGreenRefuses() {
        // The second measured hole, and the reason Task 1 exists. Nothing here
        // built anything; a hosted analyser and a Renovate status both count as
        // successes to GitHub's aggregate rollup.
        //
        // `derived` again, and for the same reason: `ci` has to be computed by
        // `ciState` from real checks, or the names under test are the ones this
        // test made up rather than the ones a rollup produces.
        let analysersOnly = derived(checks: [check("CodeQL"), check("renovate/stability-days")])
        #expect(analysersOnly.ci == .passing(["CodeQL", "renovate/stability-days"]))
        #expect(analysersOnly.sign == nil, "the fixture no longer reproduces the hole")
        #expect(!analysersOnly.isMergeableUnattended)

        // One real build alongside them is enough — the list refuses greens, it
        // does not require purity.
        #expect(derived(checks: [check("CodeQL"), check("build-and-test")]).isMergeableUnattended)
    }

    @Test("No check at all is never a green, however clean the merge is")
    func noChecksRefuses() {
        #expect(!reading(ci: .noChecks, sign: nil).isMergeableUnattended)
        #expect(!reading(ci: .running, sign: nil).isMergeableUnattended)
        #expect(!reading(ci: .unknown, sign: nil).isMergeableUnattended)
        #expect(!reading(ci: .failing(["build"]), sign: nil).isMergeableUnattended)
    }

    @Test("An unreviewed pull request on a solo repository still merges")
    func noReviewIsNotARefusal() {
        // `ReviewState.none` is every pull request on a repository with one
        // author, so refusing it would refuse the whole board. `PRSign` already
        // makes that call — this states that the predicate does not add a
        // second, stricter opinion of its own.
        #expect(reading(review: .none).isMergeableUnattended)
    }
}
