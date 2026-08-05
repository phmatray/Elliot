import ElliotModel
import Foundation
import Testing

@testable import ElliotIPC

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

private func card(
    column: ElliotModel.Column,
    title: String = "Add a dark mode toggle",
    issueNumber: Int? = nil,
    prNumber: Int? = nil
) -> Card {
    Card(
        repoID: UUID(),
        title: title,
        column: column,
        orderIndex: 1024,
        issueNumber: issueNumber,
        prNumber: prNumber,
        columnEnteredAt: fixedDate,
        createdAt: fixedDate,
        updatedAt: fixedDate
    )
}

private func step(
    _ card: Card,
    repoName: String = "phmatray/Elliot",
    repoIsEnabled: Bool = true
) -> NextStep {
    let candidates = nextCandidates(
        cards: [card],
        repos: [Repo(
            id: card.repoID,
            path: "/tmp/elliot",
            nameWithOwner: repoName,
            displayName: repoName,
            isEnabled: repoIsEnabled
        )],
        activeRunIDs: [:]
    )
    return rankNextSteps(candidates)[0]
}

/// One rendering, because there is one question.
///
/// The app renders `board_next` from the running board and the helper renders it
/// from a snapshot. Written twice, the two answers to the same question drifted:
/// the helper told every card that ran nothing that "Elliot moves this card
/// itself when it notices the pull request is ready", which is false for a
/// backlog card already carrying an issue number — nothing is watching a pull
/// request that does not exist, and an agent that believes the sentence stops.
@Suite("Rendering what to do next")
struct NextRenderingTests {

    @Test("A card in flight is described as waiting on Elliot")
    func inFlightWaitsOnElliot() {
        let dto = NextDTO(step: step(card(column: .inProgress)), rank: 1, activeRunID: nil)

        #expect(!dto.isReady)
        #expect(dto.blockCode == NextBlockCode.nothingToTrigger)
        #expect(dto.blockReason?.contains("pull request is ready") == true)
        #expect(dto.summary.contains("in flight"))
    }

    @Test("A card that already carries its issue is not described as waiting on a pull request")
    func alreadyFiledIsNotWaitingOnAPullRequest() {
        // backlog → todo with an issue number already on the card: the rule
        // engine allows the move and triggers nothing, because filing the issue
        // a second time is exactly what must not happen. There is no pull
        // request here and nothing will ever move this card on its own.
        let dto = NextDTO(
            step: step(card(column: .backlog, issueNumber: 42)),
            rank: 1,
            activeRunID: nil
        )

        #expect(!dto.isReady)
        #expect(dto.blockCode == NextBlockCode.nothingToTrigger)
        #expect(dto.blockReason?.contains("pull request") == false)
        #expect(dto.blockReason?.contains("already carries") == true)
        #expect(dto.summary.contains("nothing would run"))
    }

    @Test("A ready card names the skill the move runs, in the wire's vocabulary")
    func readyNamesItsSkill() {
        let merge = NextDTO(
            step: step(card(column: .inReview, prNumber: 7)),
            rank: 2,
            activeRunID: nil
        )

        #expect(merge.isReady)
        #expect(merge.wouldTrigger == "merge-pr")
        #expect(merge.nextColumn == "done")
        #expect(merge.blockCode == nil)
        #expect(merge.rank == 2)
    }

    @Test("A blocked card carries the same code board_move_card would return, plus the way out")
    func blockedCarriesCodeAndHint() {
        let dto = NextDTO(step: step(card(column: .todo)), rank: 1, activeRunID: nil)

        #expect(dto.blockCode == MoveBlock.missingIssueNumber.code)
        #expect(dto.blockReason == MoveBlockText.explain(.missingIssueNumber))
        #expect(dto.blockHint == MoveBlockText.hint(.missingIssueNumber))
        #expect(dto.summary.contains("cannot go"))
    }

    @Test("Every block has words, and the ones with a way out say what it is")
    func everyBlockIsExplained() {
        let blocks: [MoveBlock] = [
            .sameColumn, .emptyIdea, .incompleteStory, .missingIssueNumber,
            .missingPRNumber, .repoDisabled, .runAlreadyInFlight(runID: UUID()),
        ]
        for block in blocks {
            #expect(!MoveBlockText.explain(block).isEmpty, "\(block.code)")
        }
        // A hint that names no gesture is worse than none, so the two that have
        // nothing to suggest say nothing.
        #expect(MoveBlockText.hint(.sameColumn) == nil)
        #expect(MoveBlockText.hint(.emptyIdea) == nil)
        #expect(MoveBlockText.hint(.incompleteStory)?.contains("board_update_card") == true)
    }

    @Test("The run holding a card is on the card the answer carries")
    func activeRunReachesTheCard() {
        let runID = UUID()
        let dto = NextDTO(step: step(card(column: .backlog)), rank: 1, activeRunID: runID)

        #expect(dto.card.activeRunID == runID)
    }

    // MARK: - Candidates

    @Test("A card whose repository is gone is not a candidate on either path")
    func cardWithoutARepositoryIsDropped() {
        // Hard to reach — the foreign key cascades — but the app dropped it and
        // the helper kept it under the name "?", so one board answered `total: 0`
        // and `total: 1` depending on whether Elliot happened to be running.
        let orphan = card(column: .backlog)
        #expect(nextCandidates(cards: [orphan], repos: [], activeRunIDs: [:]).isEmpty)
    }

    @Test("Candidates are evaluated as if follow-ups were asked for and none given")
    func candidatesCarryAnEmptyFollowUpList() throws {
        // `nil` would mean "not collected yet" and make every inReview card read
        // as needing input — the one move an agent can actually make reported as
        // blocked.
        let merge = card(column: .inReview, prNumber: 7)
        let repo = Repo(
            id: merge.repoID, path: "/tmp/e", nameWithOwner: "phmatray/Elliot", displayName: "Elliot"
        )
        let candidate = try #require(
            nextCandidates(cards: [merge], repos: [repo], activeRunIDs: [:]).first
        )

        #expect(candidate.context.providedFollowUps == [])
        #expect(candidate.context.allowSideEffects)
        #expect(rankNextSteps([candidate])[0].isReady)
    }
}

/// The one place the build's own version is decided.
///
/// Split from `Bundle.main` because that answers differently in an app bundle,
/// in a bare command-line binary and under a test runner — and a version string
/// is only ever read once something has already gone wrong.
@Suite("Naming the build")
struct ElliotBuildTests {

    @Test("A bundle that names both a version and a build reports both")
    func bothFields() {
        #expect(ElliotBuild.describe(short: "0.2.0", build: "34") == "0.2.0 (34)")
    }

    @Test("A version with no build number is reported alone")
    func shortOnly() {
        #expect(ElliotBuild.describe(short: "0.2.0", build: nil) == "0.2.0")
    }

    @Test("A build number with no version falls back to the one in the source")
    func buildOnly() {
        #expect(ElliotBuild.describe(short: nil, build: "34")
            == "\(ElliotBuild.marketingVersion) (34)")
    }

    @Test("No bundle at all still names a version, marked as a working-tree build")
    func neither() {
        // "unknown", which this replaces, named nothing — and the moment a
        // version matters is a bug report about behaviour that no longer exists
        // in the source.
        let described = ElliotBuild.describe(short: nil, build: nil)
        #expect(described == "\(ElliotBuild.marketingVersion)+dev")
        #expect(!described.contains("unknown"))
    }

    @Test("The version the source declares is the one the app bundle is stamped with")
    func marketingVersionIsTheSingleSource() throws {
        // `Scripts/build-app.sh` reads `marketingVersion` out of this file with
        // sed. Written twice, a plist can claim a version the code does not —
        // and the plist is the half a bug report is trusted on.
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ElliotIPCTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // ElliotKit
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("Scripts/build-app.sh")
        let text = try String(contentsOf: script, encoding: .utf8)

        #expect(text.contains("marketingVersion"))
        // The literal must not be in there as well, or the two can disagree.
        #expect(!text.contains("<string>\(ElliotBuild.marketingVersion)</string>"))
    }
}
