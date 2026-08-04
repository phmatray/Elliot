import Foundation

/// What a card move should cause to run.
public enum TriggerAction: Equatable, Sendable, Hashable {
    /// `create-issue` reads free text and infers scope from it, so the idea is
    /// one string — normally a user story's narrative and acceptance criteria.
    case createIssue(idea: String)
    case implementIssue(issueNumber: Int)
    case mergePR(prNumber: Int, followUps: [String])
}

/// Why a move was refused. Each case carries enough for the UI to say
/// something actionable and for the MCP layer to return a machine-readable code.
public enum MoveBlock: Equatable, Sendable, Hashable {
    case sameColumn
    /// Nothing to file: no story, no title, no body.
    case emptyIdea
    /// A story was started but one of role / want / benefit is still blank.
    case incompleteStory
    case missingIssueNumber
    case missingPRNumber
    case repoDisabled
    case runAlreadyInFlight(runID: UUID)

    /// Stable identifier surfaced to MCP callers.
    public var code: String {
        switch self {
        case .sameColumn: "same_column"
        case .emptyIdea: "empty_idea"
        case .incompleteStory: "incomplete_story"
        case .missingIssueNumber: "missing_issue_number"
        case .missingPRNumber: "missing_pr_number"
        case .repoDisabled: "repo_disabled"
        case .runAlreadyInFlight: "run_already_in_flight"
        }
    }
}

/// Information the move needs before it can be decided, and that only a human
/// (or an explicit tool argument) can supply.
public enum NeedsInput: Equatable, Sendable, Hashable {
    case followUps(prNumber: Int)
}

public enum MoveOutcome: Equatable, Sendable, Hashable {
    /// Move the card; run nothing.
    case noAction
    /// Move the card and enqueue this.
    case action(TriggerAction)
    /// Don't move yet — collect input, then evaluate again.
    case needsInput(NeedsInput)
    /// Don't move at all.
    case blocked(MoveBlock)
}

/// Everything outside the card that the decision depends on.
///
/// Deliberately plain data: `evaluateMove` must stay pure so the whole
/// transition matrix is exhaustively testable without a database or a clock.
public struct MoveContext: Equatable, Sendable, Hashable {
    public var repoIsEnabled: Bool
    public var activeRunID: UUID?

    /// `false` for moves the app makes on its own behalf — reconciliation, or
    /// the PR watcher noticing a PR went ready. Such a move must never trigger
    /// a skill: the state it is reacting to was *produced* by one.
    public var allowSideEffects: Bool

    /// `nil` means "not collected yet" and produces `.needsInput`. An explicit
    /// empty array means "no follow-ups" and lets the merge proceed.
    public var providedFollowUps: [String]?

    public init(
        repoIsEnabled: Bool = true,
        activeRunID: UUID? = nil,
        allowSideEffects: Bool = true,
        providedFollowUps: [String]? = nil
    ) {
        self.repoIsEnabled = repoIsEnabled
        self.activeRunID = activeRunID
        self.allowSideEffects = allowSideEffects
        self.providedFollowUps = providedFollowUps
    }
}

/// Decides what a column change means. Pure: no I/O, no clock, no randomness.
///
/// This is the single definition of the board's behaviour. A manual drag and an
/// MCP `board_move_card` both reach it through `BoardService`, so the two can
/// not diverge.
public func evaluateMove(
    from: Column,
    to: Column,
    card: Card,
    context: MoveContext
) -> MoveOutcome {
    guard from != to else { return .blocked(.sameColumn) }

    // Checked before the guards below: a system move reacts to reality rather
    // than changing it, so it is never blocked by a run it is probably about.
    guard context.allowSideEffects else { return .noAction }

    guard context.repoIsEnabled else { return .blocked(.repoDisabled) }
    if let runID = context.activeRunID { return .blocked(.runAlreadyInFlight(runID: runID)) }

    switch (from, to) {
    case (.backlog, .todo):
        // Already filed — moving it again must not open a second issue.
        if card.issueNumber != nil { return .noAction }
        // A half-written story would file a vague issue, and `create-issue`
        // stops on "an idea too vague to even name". Catch it here instead.
        guard !card.hasIncompleteStory else { return .blocked(.incompleteStory) }
        let idea = card.ideaText
        guard !idea.isEmpty else { return .blocked(.emptyIdea) }
        return .action(.createIssue(idea: idea))

    case (.todo, .inProgress):
        guard let issue = card.issueNumber else { return .blocked(.missingIssueNumber) }
        return .action(.implementIssue(issueNumber: issue))

    case (.inReview, .done):
        guard let pr = card.prNumber else { return .blocked(.missingPRNumber) }
        guard let followUps = context.providedFollowUps else {
            return .needsInput(.followUps(prNumber: pr))
        }
        return .action(.mergePR(prNumber: pr, followUps: followUps))

    default:
        return .noAction
    }
}
