import Foundation
import Testing

@testable import ElliotModel

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

private func card(
    id: UUID = UUID(),
    column: Column = .backlog,
    orderIndex: Double = 1024,
    title: String = "Add a dark mode toggle",
    issueNumber: Int? = nil,
    prNumber: Int? = nil
) -> Card {
    Card(
        id: id,
        repoID: UUID(),
        title: title,
        column: column,
        orderIndex: orderIndex,
        issueNumber: issueNumber,
        prNumber: prNumber,
        columnEnteredAt: fixedDate,
        createdAt: fixedDate,
        updatedAt: fixedDate
    )
}

private func candidate(
    _ card: Card,
    repoName: String = "phmatray/Elliot",
    followUps: [String]? = []
) -> NextCandidate {
    NextCandidate(
        card: card,
        repoName: repoName,
        context: MoveContext(
            method: MethodCatalog.resolve(nil),
            providedFollowUps: followUps,
            // What `nextCandidates` itself answers — see
            // `nextCandidatesAnswerForAHumansProxy` below for why.
            requiresVerifiedGreen: false,
            prVerdict: nil
        )
    )
}

@Suite("Next steps")
struct NextStepTests {

    @Test("Every column has one step forward, and Done has none")
    func naturalNext() {
        #expect(Column.backlog.naturalNext == .todo)
        #expect(Column.todo.naturalNext == .inProgress)
        #expect(Column.inProgress.naturalNext == .inReview)
        #expect(Column.inReview.naturalNext == .done)
        #expect(Column.done.naturalNext == nil)
    }

    @Test("Skills are named the same way everywhere on the wire")
    func skillNames() {
        #expect(SkillKind.createIssue.skillName == "create-issue")
        #expect(SkillKind.implementIssue.skillName == "implement-issue")
        #expect(SkillKind.mergePR.skillName == "merge-pr")
    }

    @Test("A Done card is not a candidate — it has nowhere to go")
    func doneIsNotACandidate() {
        #expect(rankNextSteps([candidate(card(column: .done))]).isEmpty)
    }

    @Test("Only a move that would start work counts as ready")
    func readyMeansActionable() {
        let ready = rankNextSteps([candidate(card(column: .backlog))])
        #expect(ready.first?.isReady == true)
        #expect(ready.first?.triggers == .createIssue(idea: "Add a dark mode toggle"))

        // In Progress → In Review moves the card and runs nothing: Elliot makes
        // that move itself when the pull request goes ready.
        let inert = rankNextSteps([candidate(card(column: .inProgress, issueNumber: 47))])
        #expect(inert.first?.isReady == false)
        #expect(inert.first?.outcome == .noAction)

        let blocked = rankNextSteps([candidate(card(column: .todo))])
        #expect(blocked.first?.isReady == false)
        #expect(blocked.first?.block == .missingIssueNumber)
    }

    @Test("Ready cards come first, then the ones nearest to done")
    func readyThenNearestDone() {
        let backlogReady = card(column: .backlog)
        let todoBlocked = card(column: .todo)
        let reviewReady = card(column: .inReview, prNumber: 279)

        let ranked = rankNextSteps([todoBlocked, backlogReady, reviewReady].map { candidate($0) })

        #expect(ranked.map(\.card.id) == [reviewReady.id, backlogReady.id, todoBlocked.id])
        #expect(ranked.map(\.isReady) == [true, true, false])
    }

    @Test("Among equals the order is repository, then position, then id")
    func tiesAreBrokenTotally() {
        let first = card(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
        let second = card(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!)
        let later = card(orderIndex: 2048)
        let otherRepo = card()

        let ranked = rankNextSteps([
            candidate(later),
            candidate(otherRepo, repoName: "zzz/last"),
            candidate(second),
            candidate(first),
        ])
        #expect(ranked.map(\.card.id) == [first.id, second.id, later.id, otherRepo.id])
    }

    @Test("The answer does not depend on the order the candidates arrived in")
    func orderIndependent() {
        let cards = [
            card(column: .backlog),
            card(column: .todo, issueNumber: 47),
            card(column: .inReview, prNumber: 279),
            card(column: .inProgress),
            card(column: .todo),
        ]
        let forwards = rankNextSteps(cards.map { candidate($0) }).map(\.card.id)
        let backwards = rankNextSteps(cards.reversed().map { candidate($0) }).map(\.card.id)
        #expect(forwards == backwards)
    }

    @Test("An In Review card reads as ready because a move files no follow-ups")
    func inReviewIsReadyWithEmptyFollowUps() {
        // `board_move_card` defaults follow-ups to `[]`, so evaluating with nil
        // would report as blocked the one move an agent can actually make.
        let pending = card(column: .inReview, prNumber: 279)
        #expect(rankNextSteps([candidate(pending)]).first?.isReady == true)
        #expect(rankNextSteps([candidate(pending, followUps: nil)]).first?.isReady == false)
    }

    /// The name carries the reason, because two tests already established this
    /// by accident and neither said why.
    @Test("board_next never demands a verified green, because an agent has a human behind it")
    func nextCandidatesAnswerForAHumansProxy() throws {
        // `board_next` answers *what an agent can do*, and an agent is a
        // human's proxy with a human behind it. The restraint belongs to the
        // caller that has nobody — `AutoDevService` builds its own
        // `MoveContext`; it does not borrow the board's.
        //
        // The sharper reason is that `OfflineResponder` cannot know a verdict:
        // it holds a read-only snapshot and can reach neither `gh` nor the
        // network. If `nextCandidates` demanded one, the snapshot's answer would
        // *mean* "I could not ask" while *encoding* as "the CI is not green" —
        // and `OfflineParityTests` compares encoded bytes, so it would pass
        // green on exactly that disagreement.
        let merge = card(column: .inReview, prNumber: 7)
        let repo = Repo(
            id: merge.repoID, path: "/tmp/e", nameWithOwner: "phmatray/Elliot", displayName: "Elliot"
        )
        let candidates = nextCandidates(cards: [merge], repos: [repo], activeRunIDs: [:])
        let candidate = try #require(candidates.first)

        #expect(candidate.context.requiresVerifiedGreen == false)
        #expect(candidate.context.prVerdict == nil)
        // And the consequence that matters: it still reads as ready. A verdict
        // demanded here would have reported the one move an agent can actually
        // make as blocked.
        #expect(rankNextSteps(candidates).first?.isReady == true)
    }
}
