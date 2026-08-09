import Foundation

/// What a card move should cause to run.
public enum TriggerAction: Equatable, Sendable, Hashable {
    /// `create-issue` reads free text and infers scope from it, so the idea is
    /// one string — normally a user story's narrative and acceptance criteria.
    case createIssue(idea: String)
    case implementIssue(issueNumber: Int)
    case mergePR(prNumber: Int, followUps: [String])
}

/// Why a pull request fell short of a verified green, total by construction.
///
/// Not an optional `PRSign`: `PRSign`'s own `nil` means *everything known is
/// fine* (`PRStatus.swift:160-162`), the opposite of what a refusal needs it
/// to mean, and `ResolvedPRStatus.isMergeableUnattended` blocks two states —
/// `.unstable`, and "the only greens are analysers" — precisely where `sign`
/// reads `nil`. Passing that same optional to a refusal would have told the
/// reader "nothing was read" about a pull request that was read, resolved,
/// and found wanting. Each of those two states gets its own case here instead
/// of borrowing one that already means something else.
public enum NotGreenReason: Equatable, Sendable, Hashable {
    /// No `PRStatus` row at all — nothing has been read.
    case noReading
    /// A sign names the problem. `PRSign.summary` already says it well.
    case sign(PRSign)
    /// Read, and `mergeState` is not `.clean` — `.unstable` above all, which
    /// `PRSign` deliberately lets through because it is also a display type
    /// (`MergeableUnattended.swift`'s reason 1).
    case notClean(MergeState)
    /// Read, clean, nothing signed — and every passing check is an analyser,
    /// never a build (`MergeableUnattended.swift`'s reason 2).
    case noBuildVerdict
}

public extension NotGreenReason {
    /// The first thing actually wrong with `verdict`, so the reason a reader
    /// is given is always the first conjunct that failed rather than
    /// whichever one this happens to check last.
    ///
    /// Answers in exactly the order `ResolvedPRStatus.isMergeableUnattended`
    /// refuses in: no reading (nil or stale, which describes a commit no
    /// longer under review and so is not a reading of *this* pull request),
    /// then a sign, then an unclean merge state, then — the only conjunct
    /// left once the other three have passed — no build verdict. That last
    /// arm is a claim, not a default: it is reachable only when the reading
    /// exists, is not stale, carries no sign, and is `.clean`, so
    /// `ci.hasBuildVerdict` is the one thing that can still have failed.
    ///
    /// Truthful only when the reading it was given is *not* mergeable —
    /// called on one that is, it still answers confidently (`.noBuildVerdict`,
    /// the last arm), because it has no way to know its caller never checked
    /// `isMergeableUnattended` first. Its one call site today is inside the
    /// refusal branch of `evaluateMove`, where that is already true.
    static func of(_ verdict: ResolvedPRStatus?) -> NotGreenReason {
        guard let verdict, !verdict.isStale else { return .noReading }
        if let sign = verdict.sign { return .sign(sign) }
        if verdict.merge != .clean { return .notClean(verdict.merge) }
        return .noBuildVerdict
    }
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
    /// Nothing established that this pull request is green, and this caller may
    /// not merge on less. Carries why, as a `NotGreenReason` — see its own doc
    /// for why that is not an optional `PRSign`.
    case notVerifiedGreen(reason: NotGreenReason)
    /// This transition has one owner, and the caller is not it.
    ///
    /// Its own case rather than a second use of `notVerifiedGreen`, so the
    /// refusal is truthful: reusing that one for In Progress → In Review would
    /// tell the reader the CI is the problem when the real answer is that
    /// nobody but Elliot makes this move.
    case systemOwnedTransition

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
        case .notVerifiedGreen: "not_verified_green"
        case .systemOwnedTransition: "system_owned_transition"
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

    /// This move must not merge on anything short of a verified green.
    ///
    /// Named for the rule, not for the caller: `.mcp` and `.userDrag` set it
    /// false today, and a future caller that wants the restraint asks for it by
    /// name rather than by claiming to be unwatched. It is **set explicitly by
    /// the caller** rather than derived from `MoveOrigin`, because the word
    /// "unattended" already has a settled meaning in this package — about
    /// twenty uses in `Sources`, all naming the *child process* — under which a
    /// drag is the canonical unattended gesture.
    public var requiresVerifiedGreen: Bool

    /// What `gh` established about the pull request, already resolved against
    /// the clock and the current head. `nil` is *nothing established*, which is
    /// not a green.
    public var prVerdict: ResolvedPRStatus?

    /// ⛔ **The last two parameters have no default values, on purpose.**
    ///
    /// Every other parameter here defaults, so two defaulted ones would compile
    /// at every existing construction and nothing would catch the next one. The
    /// three production sites — `AppModel.preview`, `BoardService.proposeMove`
    /// and `nextCandidates` below — and roughly twenty test constructions each
    /// had to state an answer before this built, and so will the fourth. The
    /// template is `providedFollowUps`, whose two sites diverge deliberately.
    public init(
        repoIsEnabled: Bool = true,
        activeRunID: UUID? = nil,
        allowSideEffects: Bool = true,
        providedFollowUps: [String]? = nil,
        requiresVerifiedGreen: Bool,
        prVerdict: ResolvedPRStatus?
    ) {
        self.repoIsEnabled = repoIsEnabled
        self.activeRunID = activeRunID
        self.allowSideEffects = allowSideEffects
        self.providedFollowUps = providedFollowUps
        self.requiresVerifiedGreen = requiresVerifiedGreen
        self.prVerdict = prVerdict
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

    case (.inProgress, .inReview):
        // Filled by `PRWatcher` alone. A caller that requires a verified green
        // asking for it is asking to skip the pull request entirely, and
        // `arrivalNote` could not explain such an arrival — it speaks for moves
        // whose reason was recorded, and this one would have none.
        //
        // Stated as its own arm rather than left to `default`, which answered
        // `.noAction` for it and would go on answering `.noAction` to a loop.
        if context.requiresVerifiedGreen { return .blocked(.systemOwnedTransition) }
        return .noAction

    case (.inReview, .done):
        guard let pr = card.prNumber else { return .blocked(.missingPRNumber) }
        // Before `providedFollowUps`, on purpose. `.needsInput` is information
        // "only a human (or an explicit tool argument) can supply"; a caller
        // with no human reads it as "blocked, I will try again", which is a loop
        // that spins. Every refusal it can meet here is therefore a `.blocked`.
        if context.requiresVerifiedGreen {
            guard let verdict = context.prVerdict, verdict.isMergeableUnattended
            else { return .blocked(.notVerifiedGreen(reason: NotGreenReason.of(context.prVerdict))) }
        }
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
                activeRunID: activeRunIDs[card.id],
                allowSideEffects: true,
                // `[]` and not nil. Nil means "not collected yet" and would
                // report every inReview card as needing input, when the move an
                // agent can actually make — merge, filing nothing after it — is
                // available to it right now.
                providedFollowUps: [],
                // `board_next` answers what an *agent* can do, and an agent is
                // a human's proxy with a human behind it. The restraint belongs
                // to the caller that has nobody: `AutoDevService` builds its own
                // context rather than borrowing this one.
                //
                // And the helper could not honour it if it were true:
                // `OfflineResponder` reads a snapshot and can reach neither
                // `gh` nor the network, so its answer would *mean* "I could not
                // ask" while *encoding* as "the CI is not green" — and
                // `OfflineParityTests` compares encoded bytes, so it would hold
                // on exactly that disagreement.
                requiresVerifiedGreen: false,
                prVerdict: nil
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
