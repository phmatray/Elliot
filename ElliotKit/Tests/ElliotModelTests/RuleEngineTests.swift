import Foundation
import Testing

@testable import ElliotModel

private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
private let repoID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

private func makeCard(
    title: String = "Add a dark mode toggle",
    body: String = "",
    column: Column = .backlog,
    issueNumber: Int? = nil,
    prNumber: Int? = nil
) -> Card {
    Card(
        repoID: repoID,
        title: title,
        body: body,
        column: column,
        issueNumber: issueNumber,
        prNumber: prNumber,
        columnEnteredAt: fixedDate,
        createdAt: fixedDate,
        updatedAt: fixedDate
    )
}

/// The three transitions that fire a skill, and nothing else does.
private let triggerTransitions: Set<[Column]> = [
    [.backlog, .todo],
    [.todo, .inProgress],
    [.inReview, .done],
]

@Suite("Rule engine")
struct RuleEngineTests {

    // MARK: - The three active transitions

    @Test("Backlog to To Do files an issue from a plain card's title and body")
    func backlogToTodoCreatesIssue() {
        let card = makeCard(title: "Add a dark mode toggle", body: "Respect the system setting.")
        let outcome = evaluateMove(from: .backlog, to: .todo, card: card, context: MoveContext())
        #expect(outcome == .action(.createIssue(
            idea: "Add a dark mode toggle. Respect the system setting."
        )))
    }

    @Test("A story card files its narrative and criteria, not its board label")
    func backlogToTodoUsesTheStory() {
        var card = makeCard(title: "Run log")
        card.story = UserStory(
            role: "developer",
            want: "to see the run log inside the card",
            benefit: "I can diagnose a failure without opening a terminal",
            acceptanceCriteria: ["the log streams live", "the log survives a relaunch"]
        )
        let outcome = evaluateMove(from: .backlog, to: .todo, card: card, context: MoveContext())
        #expect(outcome == .action(.createIssue(
            idea: "As a developer, I want to see the run log inside the card, so that I can "
                + "diagnose a failure without opening a terminal. Acceptance criteria: "
                + "1) the log streams live 2) the log survives a relaunch"
        )))
    }

    @Test("A story missing one of its three parts is refused before it reaches the skill")
    func incompleteStoryBlocked() {
        var card = makeCard(title: "Run log")
        card.story = UserStory(role: "developer", want: "to see the run log", benefit: "  ")
        let outcome = evaluateMove(from: .backlog, to: .todo, card: card, context: MoveContext())
        #expect(outcome == .blocked(.incompleteStory))
    }

    @Test("To Do to In Progress implements the card's issue")
    func todoToInProgressImplements() {
        let card = makeCard(column: .todo, issueNumber: 47)
        let outcome = evaluateMove(from: .todo, to: .inProgress, card: card, context: MoveContext())
        #expect(outcome == .action(.implementIssue(issueNumber: 47)))
    }

    @Test("In Review to Done merges once follow-ups are settled")
    func inReviewToDoneMerges() {
        let card = makeCard(column: .inReview, prNumber: 279)
        let context = MoveContext(providedFollowUps: ["add snapshot tests"])
        let outcome = evaluateMove(from: .inReview, to: .done, card: card, context: context)
        #expect(outcome == .action(.mergePR(prNumber: 279, followUps: ["add snapshot tests"])))
    }

    @Test("In Progress to In Review fires nothing — implement-issue already did the work")
    func inProgressToInReviewIsInert() {
        let card = makeCard(column: .inProgress, issueNumber: 47, prNumber: 279)
        let outcome = evaluateMove(from: .inProgress, to: .inReview, card: card, context: MoveContext())
        #expect(outcome == .noAction)
    }

    // MARK: - Refusals

    @Test("A move to the same column is refused")
    func sameColumnBlocked() {
        for column in Column.allCases {
            let outcome = evaluateMove(
                from: column, to: column, card: makeCard(column: column), context: MoveContext()
            )
            #expect(outcome == .blocked(.sameColumn))
        }
    }

    @Test("Implementing without an issue number is refused")
    func todoToInProgressWithoutIssue() {
        let card = makeCard(column: .todo, issueNumber: nil)
        let outcome = evaluateMove(from: .todo, to: .inProgress, card: card, context: MoveContext())
        #expect(outcome == .blocked(.missingIssueNumber))
    }

    @Test("Merging without a PR number is refused")
    func inReviewToDoneWithoutPR() {
        let card = makeCard(column: .inReview, prNumber: nil)
        let context = MoveContext(providedFollowUps: [])
        let outcome = evaluateMove(from: .inReview, to: .done, card: card, context: context)
        #expect(outcome == .blocked(.missingPRNumber))
    }

    @Test("A card with nothing in it cannot become an issue", arguments: ["", "   ", "\n\t "])
    func backlogToTodoWithBlankIdea(title: String) {
        let card = makeCard(title: title, body: "")
        let outcome = evaluateMove(from: .backlog, to: .todo, card: card, context: MoveContext())
        #expect(outcome == .blocked(.emptyIdea))
    }

    @Test("A disabled repo refuses every move")
    func disabledRepoBlocks() {
        let context = MoveContext(repoIsEnabled: false)
        let card = makeCard(column: .todo, issueNumber: 47)
        let outcome = evaluateMove(from: .todo, to: .inProgress, card: card, context: context)
        #expect(outcome == .blocked(.repoDisabled))
    }

    @Test("A card with a run in flight refuses every move")
    func activeRunBlocks() {
        let runID = UUID()
        let context = MoveContext(activeRunID: runID)
        let card = makeCard(column: .todo, issueNumber: 47)
        let outcome = evaluateMove(from: .todo, to: .inProgress, card: card, context: context)
        #expect(outcome == .blocked(.runAlreadyInFlight(runID: runID)))
    }

    // MARK: - Re-filing guard

    @Test("A card that already has an issue is not filed again")
    func backlogToTodoWithExistingIssueIsInert() {
        let card = makeCard(issueNumber: 47)
        let outcome = evaluateMove(from: .backlog, to: .todo, card: card, context: MoveContext())
        #expect(outcome == .noAction)
    }

    // MARK: - Follow-ups

    @Test("Merging asks for follow-ups when they have not been collected")
    func inReviewToDoneNeedsFollowUps() {
        let card = makeCard(column: .inReview, prNumber: 279)
        let context = MoveContext(providedFollowUps: nil)
        let outcome = evaluateMove(from: .inReview, to: .done, card: card, context: context)
        #expect(outcome == .needsInput(.followUps(prNumber: 279)))
    }

    @Test("An explicit empty follow-up list means 'none', and merges")
    func emptyFollowUpsIsAnAnswer() {
        let card = makeCard(column: .inReview, prNumber: 279)
        let context = MoveContext(providedFollowUps: [])
        let outcome = evaluateMove(from: .inReview, to: .done, card: card, context: context)
        #expect(outcome == .action(.mergePR(prNumber: 279, followUps: [])))
    }

    // MARK: - The system-move invariant

    @Test(
        "A system move never triggers a skill",
        arguments: Column.allCases, Column.allCases
    )
    func systemMovesNeverTrigger(from: Column, to: Column) {
        // Fully-populated card: every trigger's precondition is satisfied, so
        // only `allowSideEffects` can be what holds the action back.
        let card = makeCard(column: from, issueNumber: 47, prNumber: 279)
        let context = MoveContext(allowSideEffects: false, providedFollowUps: [])
        let outcome = evaluateMove(from: from, to: to, card: card, context: context)

        if from == to {
            #expect(outcome == .blocked(.sameColumn))
        } else {
            #expect(outcome == .noAction)
        }
    }

    @Test("A system move is not held back by an in-flight run")
    func systemMoveIgnoresActiveRun() {
        // The PR watcher sees the PR go ready while implement-issue is still
        // wrapping up. That move must land, not wait for the run to exit.
        let card = makeCard(column: .inProgress, issueNumber: 47, prNumber: 279)
        let context = MoveContext(activeRunID: UUID(), allowSideEffects: false)
        let outcome = evaluateMove(from: .inProgress, to: .inReview, card: card, context: context)
        #expect(outcome == .noAction)
    }

    // MARK: - Exhaustive matrix

    @Test(
        "Only the three declared transitions ever produce an action",
        arguments: Column.allCases, Column.allCases
    )
    func onlyDeclaredTransitionsAct(from: Column, to: Column) {
        let card = makeCard(column: from, issueNumber: 47, prNumber: 279)
        let context = MoveContext(providedFollowUps: [])
        let outcome = evaluateMove(from: from, to: to, card: card, context: context)

        let isTrigger = triggerTransitions.contains([from, to])
        switch outcome {
        case .action:
            #expect(isTrigger, "\(from) → \(to) produced an action but is not a declared trigger")
        case .noAction:
            // backlog → todo on a card that already has an issue is a declared
            // trigger that correctly declines to re-file.
            #expect(!isTrigger || [from, to] == [.backlog, .todo])
        case .blocked(let block):
            #expect(from == to && block == .sameColumn)
        case .needsInput:
            Issue.record("\(from) → \(to) asked for input despite follow-ups being supplied")
        }
    }

    @Test(
        "Every transition is decided — no crash, no ambiguity",
        arguments: Column.allCases, Column.allCases
    )
    func totality(from: Column, to: Column) {
        // A bare card: no issue, no PR, nothing collected. Exercises the
        // refusal paths across the whole matrix.
        let card = makeCard(column: from)
        _ = evaluateMove(from: from, to: to, card: card, context: MoveContext())
    }
}
