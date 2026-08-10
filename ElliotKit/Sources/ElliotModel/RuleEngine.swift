import Foundation

/// What a card move should cause to run.
public enum TriggerAction: Equatable, Sendable, Hashable {
    /// `create-issue` reads free text and infers scope from it, so the idea is
    /// one string — normally a user story's narrative and acceptance criteria.
    ///
    /// `labels` is what the *card* asked for, and it is the one thing here the
    /// skill would otherwise decide for itself. Defaulted to none, the way
    /// `createCard(angle:)` is: an empty list is the common path and produces
    /// the prompt this skill has always been sent, byte for byte.
    case createIssue(idea: String, labels: [String] = [])
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
    /// The repository names a method this build's catalogue does not carry.
    ///
    /// Blocks every transition rather than only the ones that run something: we
    /// do not know what *any* of them would run, and running another method's
    /// commands unannounced — at `bypassPermissions`, in a real checkout — is
    /// the silent substitution `MethodResolution` was made three-valued to
    /// refuse.
    case unknownMethod(String)
    /// The repository's method declares no step for this transition.
    ///
    /// Not a defect: the shipped BMAD pack carries project requirements and no
    /// steps at all, and GSD declares only its first. Borrowing another method's
    /// command here would be the same substitution one case up.
    case methodHasNoStep(method: String, kind: String)
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
        case .unknownMethod: "unknown_method"
        case .methodHasNoStep: "method_has_no_step"
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

    /// Which method this repository runs, resolved.
    ///
    /// ⚠️ **Defaulted, unlike `repoPreflight`, and the difference is not an
    /// oversight.** `.notChecked` is that field's default precisely so a caller
    /// who has not measured cannot assert a pass by leaving an argument out.
    /// Omitting *this* one asserts "this repository never chose a method", which
    /// is a real state, the commonest one, and exactly what every board did
    /// before method packs existed — so the default preserves the meaning every
    /// caller written before it was added already had, rather than quietly
    /// changing it.
    ///
    /// It lives here because the alternative was measured and shipped for a day:
    /// `BoardService.makeRun` refused by throwing, *downstream* of
    /// `evaluateMove`, so a BMAD repository — which declares no steps — read
    /// **ready** in `board_next` and on the drop caption and then threw at
    /// commit. Nothing spawned, and the board still lied about itself.
    public var method: MethodResolution = MethodCatalog.resolve(nil)

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
        method: MethodResolution = MethodCatalog.resolve(nil),
        activeRunID: UUID? = nil,
        allowSideEffects: Bool = true,
        providedFollowUps: [String]? = nil
    ) {
        self.repoIsEnabled = repoIsEnabled
        self.repoPreflight = repoPreflight
        self.method = method
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

    // Beside `repoBlocked`, and after it: a repository Preflight refused is
    // refused for *that* reason whatever its method, so the sentence on screen
    // names the remedy that actually applies. An id no pack answers blocks every
    // transition, including the ones that run nothing — we do not know what any
    // of them would do.
    if case .unknown(let id) = context.method { return .blocked(.unknownMethod(id)) }

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
        // Whatever the card says, unfiltered. Whether the repository still has
        // a label is not knowable here — this function is pure, and `gh` is the
        // only thing that could answer — so the card's request travels intact
        // and the skill drops what it cannot apply. Quietly stripping one on
        // the way past would lose the request without telling anyone.
        return offer(.createIssue(idea: idea, labels: card.labels), from: context.method)

    case (.todo, .inProgress):
        guard let issue = card.issueNumber else { return .blocked(.missingIssueNumber) }
        return offer(.implementIssue(issueNumber: issue), from: context.method)

    case (.inReview, .done):
        guard let pr = card.prNumber else { return .blocked(.missingPRNumber) }
        guard let followUps = context.providedFollowUps else {
            return .needsInput(.followUps(prNumber: pr))
        }
        return offer(.mergePR(prNumber: pr, followUps: followUps), from: context.method)

    default:
        return .noAction
    }
}

/// The action a transition produces — or the refusal that this repository's
/// method has no step to run for it.
///
/// Called at the action sites rather than beside the other guards because it is
/// the one refusal that depends on *which* skill the transition produces: GSD
/// declares `create-issue` and nothing else, so it is offered Backlog → To Do
/// and refused the other two. A per-repository check could not express that.
///
/// `.unknown` is unreachable here — `evaluateMove` refuses it before the
/// transition switch — and is answered rather than force-unwrapped so this stays
/// total, with no `default:` for a fourth `MethodResolution` case to hide in.
private func offer(_ action: TriggerAction, from method: MethodResolution) -> MoveOutcome {
    let pack: MethodPack
    switch method {
    case .unset(let resolved), .chosen(let resolved): pack = resolved
    case .unknown(let id): return .blocked(.unknownMethod(id))
    }
    guard pack.steps[action.kind] != nil else {
        return .blocked(
            .methodHasNoStep(method: pack.displayName, kind: action.kind.skillName)
        )
    }
    return .action(action)
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
                // Without this the ranking answered from the default pack for
                // every repository, so `board_next` offered a card whose only
                // forward move `commitMove` would refuse — finding I2.
                method: repo.method,
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
