import Foundation
import Testing

@testable import ElliotModel

/// Every symbol PR4 borrows from PR 0·2 and PR1, named once, in one file.
///
/// Its job is to fail **by name**. PR4 is the last engine PR of the auto-dev
/// design and consumes four things it cannot supply; without this file the
/// first sign of an absent prerequisite is a compile error inside
/// `AutoDevService`, where it reads as a defect in the new code rather than as
/// a missing dependency. The same discipline `swift-floor.yml` applies to the
/// toolchain: a tools-version refusal at manifest parse beats a mystery.
@Suite("Auto-dev preconditions")
struct AutoDevPreconditionTests {

    private func card(column: Column, prNumber: Int? = nil) -> Card {
        let now = Date(timeIntervalSince1970: 1_000_000)
        return Card(
            repoID: UUID(), title: "Anything", column: column,
            prNumber: prNumber, columnEnteredAt: now, createdAt: now, updatedAt: now
        )
    }

    /// A reading built through `PRStatus.resolved(now:currentHeadOid:)` rather
    /// than by hand, because that is the path production takes: `PRWatcher`
    /// and the panel both read a `PRStatus` row through this method, never a
    /// literal `ResolvedPRStatus`. A rollup expressed as the checks `gh`
    /// actually renders is what this helper builds.
    private func reading(
        checks: [GHMergeStatus.StatusCheck] = [
            GHMergeStatus.StatusCheck(
                name: "build-and-test", conclusion: "SUCCESS", status: "COMPLETED")
        ],
        mergeStateStatus: String = "CLEAN",
        mergeable: String = "MERGEABLE",
        secondsOld: TimeInterval = 0
    ) -> ResolvedPRStatus {
        let checkedAt = Date(timeIntervalSince1970: 1_000_000)
        let status = PRStatus(
            repoID: UUID(), prNumber: 52, headRefOid: "a1b2c3", checkedAt: checkedAt,
            rawMergeStateStatus: mergeStateStatus, rawMergeable: mergeable,
            rawReviewDecision: "", checks: checks
        )
        return status.resolved(
            now: checkedAt.addingTimeInterval(secondsOld), currentHeadOid: "a1b2c3")
    }

    @Test("The origin auto-dev moves under exists, and is allowed to fire skills")
    func originExists() {
        let origin = MoveOrigin.autoDev(sessionID: UUID())
        #expect(origin.allowsSideEffects)
    }

    @Test("The two refusals PR4's policy switches over exist, with their wire codes")
    func blocksExist() {
        #expect(MoveBlock.notVerifiedGreen(reason: .noBuildVerdict).code == "not_verified_green")
        #expect(MoveBlock.systemOwnedTransition.code == "system_owned_transition")
        #expect(MoveBlock.repoBlocked.code == "repo_blocked")
    }

    @Test("A move that demands a verified green is blocked on anything short of one")
    func contextCarriesTheRule() {
        let context = MoveContext(
            repoIsEnabled: true,
            method: MethodCatalog.resolve(nil),
            activeRunID: nil, allowSideEffects: true,
            providedFollowUps: [],
            requiresVerifiedGreen: true,
            prVerdict: reading(checks: [
                GHMergeStatus.StatusCheck(
                    name: "build-and-test", conclusion: "FAILURE", status: "COMPLETED")
            ])
        )
        let outcome = evaluateMove(
            from: .inReview, to: .done, card: card(column: .inReview, prNumber: 52),
            context: context
        )
        #expect(outcome == .blocked(.notVerifiedGreen(reason: .sign(.checksFailing(count: 1)))))
    }

    @Test("A clean, fresh, unsigned reading is mergeable unattended; a stale one is not")
    func predicateExists() {
        #expect(reading().isMergeableUnattended)
        #expect(reading(secondsOld: PRStatus.maximumAge + 1).isMergeableUnattended == false)
        // `UNSTABLE` is the case `sign == nil` alone lets through: nothing is
        // signed, and GitHub still will not call the pull request clean.
        #expect(reading(mergeStateStatus: "UNSTABLE").isMergeableUnattended == false)
    }
}
