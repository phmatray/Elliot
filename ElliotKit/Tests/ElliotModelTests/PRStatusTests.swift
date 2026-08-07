import Foundation
import Testing

@testable import ElliotModel

// A check as `gh` actually renders one. A CheckRun carries `status` and
// `conclusion`; a legacy StatusContext carries `context` and `state`. Both
// shapes arrive in the same array, which is why the helpers are separate.
private func run(_ name: String, _ conclusion: String?, status: String = "COMPLETED")
    -> GHMergeStatus.StatusCheck
{
    GHMergeStatus.StatusCheck(name: name, conclusion: conclusion, status: status)
}

private func legacy(_ context: String, _ state: String) -> GHMergeStatus.StatusCheck {
    GHMergeStatus.StatusCheck(context: context, state: state)
}

private let repoID = UUID()
private let head = "a1b2c3d4e5f6"

/// The default carries one **passing** check, not none.
///
/// An empty default made `.noBuild` the answer to every test, including the ones
/// asking about review and mergeability — three failed on their fixture rather
/// than on the code. A fixture's unrelated facets have to be neutral, or the
/// test is not about what its name says.
private func status(
    checks: [GHMergeStatus.StatusCheck] = [run("build", "SUCCESS")],
    mergeStateStatus: String = "CLEAN",
    mergeable: String = "MERGEABLE",
    reviewDecision: String = "",
    headRefOid: String = head,
    checkedAt: Date = Date(timeIntervalSince1970: 1_000_000)
) -> PRStatus {
    PRStatus(
        repoID: repoID,
        prNumber: 52,
        headRefOid: headRefOid,
        checkedAt: checkedAt,
        rawMergeStateStatus: mergeStateStatus,
        rawMergeable: mergeable,
        rawReviewDecision: reviewDecision,
        checks: checks
    )
}

/// `checkedAt` plus a moment — inside the freshness window, so a test that is
/// not about staleness never trips over it.
private let soon = Date(timeIntervalSince1970: 1_000_060)

private extension PRStatus {
    /// The common case: fresh, and the head is where we left it.
    var fresh: ResolvedPRStatus { resolved(now: soon, currentHeadOid: head) }
}

@Suite("PR status")
struct PRStatusTests {

    // MARK: - CI

    @Test("No check at all is its own state — nothing has judged this pull request")
    func noChecksIsDistinct() {
        #expect(status(checks: []).fresh.ci == .noChecks)
        #expect(status(checks: []).fresh.sign == .noBuild)
    }

    @Test("A green pull request is passing, and says how many judged it")
    func passingCountsTheChecks() {
        let resolved = status(checks: [run("build", "SUCCESS"), run("test", "SUCCESS")]).fresh
        #expect(resolved.ci == .passing(2))
        // Nothing is wrong, so the card draws nothing at all — which is not the
        // same as `.unknown`, and the difference is the whole point.
        #expect(resolved.sign == nil)
    }

    @Test("A failing check names itself")
    func failingNamesTheCheck() {
        let resolved = status(checks: [run("build", "SUCCESS"), run("floor", "FAILURE")]).fresh
        #expect(resolved.ci == .failing(["floor"]))
        #expect(resolved.sign == .checksFailing(count: 1))
    }

    @Test("A check still running outranks the ones that finished green")
    func runningBeatsPassing() {
        let resolved = status(checks: [run("build", "SUCCESS"), run("test", nil, status: "IN_PROGRESS")]).fresh
        #expect(resolved.ci == .running)
        #expect(resolved.sign == .checksRunning)
    }

    @Test("A failure outranks a check that is still running — the failure is already decided")
    func failingBeatsRunning() {
        let resolved = status(checks: [run("floor", "FAILURE"), run("test", nil, status: "QUEUED")]).fresh
        #expect(resolved.ci == .failing(["floor"]))
    }

    @Test("Legacy status contexts are read too, by state rather than conclusion")
    func legacyContextsAreRead() {
        #expect(status(checks: [legacy("ci/travis", "SUCCESS")]).fresh.ci == .passing(1))
        #expect(status(checks: [legacy("ci/travis", "FAILURE")]).fresh.ci == .failing(["ci/travis"]))
        #expect(status(checks: [legacy("ci/travis", "PENDING")]).fresh.ci == .running)
    }

    @Test("A check carrying no signal at all is pending, never counted as green")
    func silentCheckIsPending() {
        #expect(status(checks: [GHMergeStatus.StatusCheck(name: "mystery")]).fresh.ci == .running)
    }

    @Test("Inert checks are NOT discounted — that judgement is deliberately not made here")
    func inertChecksStillCountAsPassing() {
        // Arbitrated on #174: encoding a non-build list in Swift would be a third
        // implementation of a rule whose data lives in repo-audit. The panel
        // prints the real names so a human judges; the model does not guess.
        let resolved = status(checks: [run("CodeQL", "SUCCESS"), run("renovate/stability-days", "SUCCESS")]).fresh
        #expect(resolved.ci == .passing(2))
        #expect(resolved.sign == nil)
    }

    // MARK: - Mergeability

    @Test("DIRTY is a conflict, and so is a CONFLICTING mergeable")
    func conflictIsRecognisedFromEitherField() {
        #expect(status(mergeStateStatus: "DIRTY").fresh.merge == .conflict)
        #expect(status(mergeStateStatus: "UNKNOWN", mergeable: "CONFLICTING").fresh.merge == .conflict)
    }

    @Test("A conflict outranks a failing check — a conflicted PR fires no workflow, so its checks are ghosts")
    func conflictOutranksFailingChecks() {
        let resolved = status(checks: [run("floor", "FAILURE")], mergeStateStatus: "DIRTY").fresh
        #expect(resolved.sign == .conflict)
    }

    @Test("mergeStateStatus UNKNOWN is not known — never clean")
    func unknownMergeStateIsNotClean() {
        // Measured on #164 and #154: GitHub computes mergeability lazily and the
        // first request answers UNKNOWN.
        let resolved = status(mergeStateStatus: "UNKNOWN", mergeable: "UNKNOWN").fresh
        #expect(resolved.merge == .unknown)
        #expect(resolved.sign == .unknown)
    }

    @Test("A value GitHub has not shipped yet degrades to unknown rather than losing the row")
    func unrecognisedMergeStateIsUnknown() {
        #expect(status(mergeStateStatus: "SOMETHING_NEW", mergeable: "SOMETHING_NEW").fresh.merge == .unknown)
    }

    @Test("The mergeable states each map to themselves", arguments: [
        ("CLEAN", MergeState.clean),
        ("HAS_HOOKS", MergeState.clean),
        ("BLOCKED", MergeState.blocked),
        ("BEHIND", MergeState.behind),
        ("UNSTABLE", MergeState.unstable),
        ("DRAFT", MergeState.blocked),
    ])
    func mergeStatesMap(raw: String, expected: MergeState) {
        #expect(status(mergeStateStatus: raw).fresh.merge == expected)
    }

    // MARK: - Review

    @Test("An empty reviewDecision means nobody reviewed, and is NEVER a sign")
    func noReviewIsNeverASign() {
        // On a solo repository nothing is ever reviewed. Treating that as
        // "a review is required" would blink every card for nothing.
        let resolved = status(reviewDecision: "").fresh
        #expect(resolved.review == .none)
        #expect(resolved.sign == nil)
    }

    @Test("Changes requested is a sign — a human is holding this")
    func changesRequestedIsASign() {
        let resolved = status(reviewDecision: "CHANGES_REQUESTED").fresh
        #expect(resolved.review == .changesRequested)
        #expect(resolved.sign == .changesRequested)
    }

    @Test("A required review is a sign too, and is not the same as nobody having looked")
    func reviewRequiredIsASign() {
        let resolved = status(reviewDecision: "REVIEW_REQUIRED").fresh
        #expect(resolved.review == .reviewRequired)
        #expect(resolved.sign == .reviewRequired)
    }

    @Test("An approval is not a problem, so it draws nothing")
    func approvedDrawsNothing() {
        let resolved = status(reviewDecision: "APPROVED").fresh
        #expect(resolved.review == .approved)
        #expect(resolved.sign == nil)
    }

    // MARK: - Staleness: the rule this type exists for

    @Test("A row read on a commit that is no longer the head is not known — never the old verdict")
    func movedHeadIsUnknown() {
        let stored = status(checks: [run("build", "SUCCESS")], mergeStateStatus: "CLEAN")
        let resolved = stored.resolved(now: soon, currentHeadOid: "9999999999")
        #expect(resolved.isStale)
        #expect(resolved.ci == .unknown)
        #expect(resolved.merge == .unknown)
        #expect(resolved.review == .unknown)
        #expect(resolved.sign == .unknown)
    }

    @Test("A row past the maximum age is not known either")
    func agedOutIsUnknown() {
        let stored = status(checks: [run("build", "SUCCESS")])
        let tooLate = stored.checkedAt.addingTimeInterval(PRStatus.maximumAge + 1)
        let resolved = stored.resolved(now: tooLate, currentHeadOid: head)
        #expect(resolved.isStale)
        #expect(resolved.sign == .unknown)
    }

    @Test("Just inside the maximum age is still trusted")
    func justInsideTheWindowIsFresh() {
        let stored = status(checks: [run("build", "SUCCESS")])
        let justInTime = stored.checkedAt.addingTimeInterval(PRStatus.maximumAge - 1)
        let resolved = stored.resolved(now: justInTime, currentHeadOid: head)
        #expect(!resolved.isStale)
        #expect(resolved.ci == .passing(1))
    }

    @Test("Not knowing the current head disables the sha rule but not the age rule")
    func nilCurrentHeadFallsBackToAgeAlone() {
        let stored = status(checks: [run("build", "SUCCESS")])
        #expect(!stored.resolved(now: soon, currentHeadOid: nil).isStale)

        let tooLate = stored.checkedAt.addingTimeInterval(PRStatus.maximumAge + 1)
        #expect(stored.resolved(now: tooLate, currentHeadOid: nil).isStale)
    }

    // MARK: - Provenance is carried, not recomputed

    @Test("The resolved value carries when it was read and on what, for the panel to show")
    func provenanceSurvivesResolution() {
        let resolved = status().fresh
        #expect(resolved.headRefOid == head)
        #expect(resolved.checkedAt == Date(timeIntervalSince1970: 1_000_000))
    }

    // MARK: - The whole precedence order, in one place

    @Test("Precedence: the sign is the most blocking known fact")
    func precedenceOrder() {
        // conflict beats everything
        #expect(
            status(checks: [run("t", "FAILURE")], mergeStateStatus: "DIRTY",
                   reviewDecision: "CHANGES_REQUESTED").fresh.sign == .conflict)
        // failing beats a requested change
        #expect(
            status(checks: [run("t", "FAILURE")], reviewDecision: "CHANGES_REQUESTED")
                .fresh.sign == .checksFailing(count: 1))
        // a requested change beats a blocked merge
        #expect(
            status(mergeStateStatus: "BLOCKED", reviewDecision: "CHANGES_REQUESTED")
                .fresh.sign == .changesRequested)
        // a blocked merge beats a running check
        #expect(
            status(checks: [run("t", nil, status: "IN_PROGRESS")], mergeStateStatus: "BLOCKED")
                .fresh.sign == .mergeBlocked)
        // a running check beats having no build at all
        #expect(status(checks: [run("t", nil, status: "IN_PROGRESS")]).fresh.sign == .checksRunning)
        // and no build at all beats saying nothing
        #expect(status(checks: []).fresh.sign == .noBuild)
    }

    @Test("A definite failure outranks an unknown mergeability — facts beat absences")
    func knownFactBeatsUnknown() {
        // The first sighting of a pull request has mergeStateStatus UNKNOWN while
        // its checks are already known. Reporting `.unknown` there would hide a
        // fact we hold.
        let resolved = status(checks: [run("floor", "FAILURE")], mergeStateStatus: "UNKNOWN",
                              mergeable: "UNKNOWN").fresh
        #expect(resolved.sign == .checksFailing(count: 1))
    }

    @Test("Every sign says something a human can act on")
    func everySignHasASummary() {
        let signs: [PRSign] = [
            .conflict, .checksFailing(count: 2), .changesRequested, .reviewRequired,
            .mergeBlocked, .checksRunning, .noBuild, .unknown,
        ]
        for sign in signs {
            #expect(!sign.summary.isEmpty, "\(sign) has no sentence")
        }
    }

    // MARK: - It survives the database round trip

    @Test("A status encodes and decodes unchanged")
    func codableRoundTrip() throws {
        let original = status(checks: [run("build", "SUCCESS"), legacy("ci/old", "PENDING")],
                              mergeStateStatus: "DIRTY", reviewDecision: "APPROVED")
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(PRStatus.self, from: data)
        #expect(back == original)
    }
}
