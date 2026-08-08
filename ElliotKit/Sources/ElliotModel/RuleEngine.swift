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
    /// Preflight swept this repository and at least one check failed.
    ///
    /// Distinct from `repoDisabled`: that one is a switch the reader threw, this
    /// one is a diagnosis Elliot made. They want different sentences and
    /// different remedies — one is turned back on, the other is repaired.
    case repoBlocked
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
        case .repoBlocked: "repo_blocked"
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

    /// What Preflight last said about the card's repository.
    ///
    /// Defaults to `.notChecked` rather than `.passing`, and the difference is
    /// the point: a caller that has not measured must not be able to assert a
    /// pass by leaving an argument out. `.notChecked` does not block — see
    /// ``PreflightState/notChecked`` for why — but it is a different answer, and
    /// a reader can render it as one.
    public var repoPreflight: PreflightState

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
        repoPreflight: PreflightState = .notChecked,
        activeRunID: UUID? = nil,
        allowSideEffects: Bool = true,
        providedFollowUps: [String]? = nil
    ) {
        self.repoIsEnabled = repoIsEnabled
        self.repoPreflight = repoPreflight
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

    // The gate three documents claimed existed and no code implemented.
    //
    // CLAUDE.md's seeding recipe said a repository drawn as blocked was safe to
    // leave on screen "because no transition can spawn an agent from it";
    // `PreflightService.isBlocking`'s doc comment said "whether a repo's cards
    // can be dragged at all"; and `labelsCheck` was deliberately made a warning
    // rather than a failure *on the strength of that belief*. Meanwhile
    // `isBlocking` was read by four views and by no rule, so a drag in a broken
    // checkout spawned `claude -p` at `bypassPermissions` inside it.
    //
    // Placed beside `repoIsEnabled` rather than in front of the `.action` cases
    // only: "this repository is not available" is one idea, and splitting it so
    // that some moves work and others do not would be a second, subtler rule to
    // keep in step. A repository Elliot has diagnosed as broken refuses moves,
    // the way one switched off does.
    guard context.repoPreflight.allowsMoves else { return .blocked(.repoBlocked) }

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

// MARK: - What to do next

/// One card, and everything outside it the decision depends on.
///
/// Plain data, gathered by whoever has a database — so the ranking itself needs
/// none.
public struct NextCandidate: Sendable, Hashable {
    public var card: Card
    public var repoName: String
    public var context: MoveContext

    public init(card: Card, repoName: String, context: MoveContext) {
        self.card = card
        self.repoName = repoName
        self.context = context
    }
}

/// A card's next move and what the rule engine says would come of it.
public struct NextStep: Sendable, Hashable {
    public var card: Card
    public var repoName: String
    public var to: Column
    public var outcome: MoveOutcome

    public init(card: Card, repoName: String, to: Column, outcome: MoveOutcome) {
        self.card = card
        self.repoName = repoName
        self.to = to
        self.outcome = outcome
    }
}

public extension NextStep {
    /// Whether moving this card now would actually start work.
    ///
    /// Only `.action` counts. `.noAction` moves the card and fires nothing — a
    /// card in progress advances when Elliot notices its pull request went
    /// ready, and there is no gesture for an agent to make there.
    var isReady: Bool {
        switch outcome {
        case .action: true
        case .noAction, .needsInput, .blocked: false
        }
    }

    var triggers: TriggerAction? {
        switch outcome {
        case .action(let action): action
        case .noAction, .needsInput, .blocked: nil
        }
    }

    var block: MoveBlock? {
        switch outcome {
        case .blocked(let block): block
        case .action, .noAction, .needsInput: nil
        }
    }
}

/// Turns a board's rows into the candidates `rankNextSteps` grades.
///
/// Shared because two callers assemble them — `BoardService` in the app and the
/// helper reading a snapshot — and a disagreement between the two is invisible:
/// they answer the same question about the same board. They had one already. A
/// card whose repository row is gone was dropped by the app and kept by the
/// helper under the name "?", so the same board answered `total: 0` live and
/// `total: 1` from the file. Dropping is the defensible half: a card with no
/// repository has no checkout to run in and no permission mode to run under.
///
/// Pure, like everything else here. Whoever holds a database does the reading
/// and hands the rows over.
///
/// `activeRunIDs` maps a card to the run holding it; a card absent from it is
/// held by nothing.
public func nextCandidates(
    cards: [Card],
    repos: [Repo],
    activeRunIDs: [UUID: UUID]
) -> [NextCandidate] {
    let byID = Dictionary(repos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return cards.compactMap { card in
        guard let repo = byID[card.repoID] else { return nil }
        return NextCandidate(
            card: card,
            repoName: repo.nameWithOwner,
            context: MoveContext(
                repoIsEnabled: repo.isEnabled,
                repoPreflight: repo.preflightVerdict,
                activeRunID: activeRunIDs[card.id],
                allowSideEffects: true,
                // `[]` and not nil. Nil means "not collected yet" and would
                // report every inReview card as needing input, when the move an
                // agent can actually make — merge, filing nothing after it — is
                // available to it right now.
                providedFollowUps: []
            )
        )
    }
}

/// Ranks cards by what the board is waiting for. Pure: no I/O, no clock, no
/// randomness — the same contract as `evaluateMove`, and for the same reason.
///
/// Every step is decided by calling `evaluateMove` on the card's natural next
/// column, so this answers with what a real move *would* do rather than with a
/// second opinion about it. That is the whole point: a board that predicts its
/// own behaviour, not a second copy of the rules that can drift from them.
///
/// The order, first difference winning: ready before blocked; then furthest
/// along the board first, because finishing work already in flight beats
/// starting more; then repository, position in column, and id. The last key
/// makes the order total, so the answer does not depend on the order the
/// candidates arrived in.
public func rankNextSteps(_ candidates: [NextCandidate]) -> [NextStep] {
    candidates
        .compactMap { candidate -> NextStep? in
            guard let to = candidate.card.column.naturalNext else { return nil }
            return NextStep(
                card: candidate.card,
                repoName: candidate.repoName,
                to: to,
                outcome: evaluateMove(
                    from: candidate.card.column,
                    to: to,
                    card: candidate.card,
                    context: candidate.context
                )
            )
        }
        .sorted { first, second in
            if first.isReady != second.isReady { return first.isReady }
            let a = first.card, b = second.card
            if a.column != b.column { return a.column.boardIndex > b.column.boardIndex }
            if first.repoName != second.repoName { return first.repoName < second.repoName }
            if a.orderIndex != b.orderIndex { return a.orderIndex < b.orderIndex }
            return a.id.uuidString < b.id.uuidString
        }
}
