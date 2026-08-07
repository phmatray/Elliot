import ElliotModel
import Foundation
import Testing

@testable import ElliotIPC

private let readAt = Date(timeIntervalSince1970: 1_700_000_000)

private func status(
    checks: [GHMergeStatus.StatusCheck] = [
        GHMergeStatus.StatusCheck(name: "build", conclusion: "SUCCESS", status: "COMPLETED"),
    ],
    mergeStateStatus: String = "CLEAN",
    mergeable: String = "MERGEABLE",
    reviewDecision: String = ""
) -> PRStatus {
    PRStatus(
        repoID: UUID(), prNumber: 52, headRefOid: "a1b2c3", checkedAt: readAt,
        rawMergeStateStatus: mergeStateStatus, rawMergeable: mergeable,
        rawReviewDecision: reviewDecision, checks: checks)
}

private func dto(_ status: PRStatus, at now: Date = readAt.addingTimeInterval(60)) -> PRStatusDTO {
    PRStatusDTO(status, resolved: status.resolved(now: now, currentHeadOid: "a1b2c3"))
}

@Suite("PR status on the wire")
struct PRStatusWireTests {

    @Test("The DTO round-trips through JSON unchanged")
    func roundTrip() throws {
        let original = dto(status(
            checks: [
                GHMergeStatus.StatusCheck(name: "build", conclusion: "SUCCESS", status: "COMPLETED"),
                GHMergeStatus.StatusCheck(name: "test", conclusion: "FAILURE", status: "COMPLETED"),
            ],
            mergeStateStatus: "DIRTY", mergeable: "CONFLICTING"))
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(PRStatusDTO.self, from: data) == original)
    }

    @Test("The facets travel separately from the sign")
    func facetsTravelSeparately() {
        // A card has room for one mark; an agent has room for the picture. The
        // combination this board sees regularly — green checks, conflicted merge
        // — is invisible if only the headline crosses the wire.
        let payload = dto(status(mergeStateStatus: "DIRTY", mergeable: "CONFLICTING"))
        #expect(payload.sign == "conflict")
        #expect(payload.merge == "conflict")
        #expect(payload.ci == "passing")
        #expect(payload.review == "none")
    }

    @Test("The real check names cross the wire, not a verdict about them")
    func checkNamesSurvive() {
        let payload = dto(status(checks: [
            GHMergeStatus.StatusCheck(name: "CodeQL", conclusion: "SUCCESS", status: "COMPLETED"),
            GHMergeStatus.StatusCheck(name: "floor", conclusion: nil, status: "IN_PROGRESS"),
        ]))
        #expect(payload.checks.map(\.name) == ["CodeQL", "floor"])
        #expect(payload.checks.last?.isPending == true)
        // Elliot does not decide that CodeQL is not a build — it prints it.
        #expect(payload.ci == "running")
    }

    @Test("Nothing to report is an absent sign, not the string \"unknown\"")
    func nothingToReportIsAbsent() {
        let payload = dto(status())
        #expect(payload.sign == nil)
        #expect(payload.summary == nil)
        #expect(!payload.isStale)
    }

    @Test("A reading with nothing to report is distinguishable from no reading at all")
    func absentReadingIsDistinguishable() {
        // `CardDTO.prStatus == nil` means Elliot never looked. A present DTO with
        // `sign == nil` means it looked and found nothing wrong. Collapsing the
        // two would report every unread card as healthy.
        let card = CardDTO(
            id: UUID(), title: "Merge me", column: "inReview", repo: "phmatray/Elliot")
        #expect(card.prStatus == nil)
        #expect(dto(status()).sign == nil)
    }

    @Test("A stale reading carries no checks — it has nothing to say about them")
    func staleReadingDropsTheChecks() {
        let payload = PRStatusDTO(
            status(), resolved: status().resolved(now: readAt, currentHeadOid: "9999999"))
        #expect(payload.isStale)
        #expect(payload.sign == "unknown")
        #expect(payload.checks.isEmpty)
        #expect(payload.ci == "unknown")
        // Provenance survives even when the verdict does not: it is what lets a
        // caller see *why* the answer is "not established".
        #expect(payload.headRefOid == "a1b2c3")
        #expect(payload.checkedAt == readAt)
    }

    @Test("Every sign and facet has a stable wire code")
    func codesAreStable() {
        // These strings are matched by agents. Renaming a Swift case must not
        // change them, which is the reason they are written out rather than
        // derived from the case name.
        #expect(PRSign.conflict.code == "conflict")
        #expect(PRSign.checksFailing(count: 2).code == "checks_failing")
        #expect(PRSign.noBuild.code == "no_build")
        #expect(CIState.noChecks.code == "no_checks")
        #expect(CIState.passing(3).code == "passing")
        #expect(MergeState.conflict.code == "conflict")
        #expect(ReviewState.changesRequested.code == "changes_requested")
    }

    @Test("The protocol version moved with the wire")
    func protocolVersionBumped() {
        // The rule this repo keeps: one number, one wire. Adding a field without
        // moving it is how a helper and an app disagree silently.
        #expect(elliotProtocolVersion >= 6)
    }
}
