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
    /// Nothing came back: either there is no `PRStatus` row at all, or a row
    /// exists and could not be checked because `gh` was unreachable.
    ///
    /// ⚠️ Those two are not the same fact, and this case cannot tell them
    /// apart — `PRVerdictReader.reading` answers `nil` to both, and widening
    /// that is a change to an interface this pull request only consumes. What
    /// this case no longer covers is a **stale** reading: staleness is the row
    /// describing a commit that is no longer the head, which is somebody
    /// pushing rather than nobody looking, and it answers `.sign(.unknown)`.
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
    /// refuses in: nothing came back, then stale, then a sign, then an unclean
    /// merge state, then — the only conjunct left once the other four have
    /// passed — no build verdict. That last arm is a claim, not a default: it
    /// is reachable only when the reading exists, is not stale, carries no
    /// sign, and is `.clean`, so `ci.hasBuildVerdict` is the one thing that can
    /// still have failed.
    ///
    /// **Stale answers `.sign(.unknown)`, not `.noReading`** — and this is the
    /// likeliest refusal in production, not a corner. Stale means the row
    /// describes a commit that is no longer the head: the ordinary case of
    /// somebody pushing while the board was deciding. `.noReading` would tell
    /// that reader nothing had been read, which is false. The accurate sentence
    /// already exists and is already written once: `resolved(now:)` stamps a
    /// stale row `sign: .unknown`, and `PRSign.unknown.summary` reads "Not
    /// established — the reading is missing, aged out, or from an older
    /// commit." The arm is stated separately rather than left to the `sign`
    /// arm below because `ResolvedPRStatus` has a public memberwise init, so
    /// `isStale: true` with `sign: nil` is constructible — the same defensive
    /// reason `isMergeableUnattended` keeps its own `!isStale` conjunct.
    ///
    /// Truthful only when the reading it was given is *not* mergeable —
    /// called on one that is, it still answers confidently (`.noBuildVerdict`,
    /// the last arm), because it has no way to know its caller never checked
    /// `isMergeableUnattended` first. Its one call site today is inside the
    /// refusal branch of `evaluateMove`, where that is already true.
    static func of(_ verdict: ResolvedPRStatus?) -> NotGreenReason {
        guard let verdict else { return .noReading }
        if verdict.isStale { return .sign(.unknown) }
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
        case .repoBlocked: "repo_blocked"
        case .unknownMethod: "unknown_method"
        case .methodHasNoStep: "method_has_no_step"
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
    /// ⛔ **Not defaulted**, for the reason the initialiser below states at
    /// length: `.unset(ai-migration-kit)` is a perfectly good *value* and a
    /// disastrous *default*, because a default is exactly what stops the
    /// compiler catching the caller who forgot. Two of the three production
    /// sites were measured unpinned while it had one.
    ///
    /// It lives here because the alternative was measured and shipped for a day:
    /// `BoardService.makeRun` refused by throwing, *downstream* of
    /// `evaluateMove`, so a BMAD repository — which declares no steps — read
    /// **ready** in `board_next` and on the drop caption and then threw at
    /// commit. Nothing spawned, and the board still lied about itself.
    public var method: MethodResolution

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

    /// ⛔ **`method`, `requiresVerifiedGreen` and `prVerdict` have no default
    /// values, on purpose.**
    ///
    /// Every other parameter here defaults, so a defaulted one would compile at
    /// every existing construction and nothing would catch the next one. The
    /// three production sites — `AppModel.preview`, `BoardService.proposeMove`
    /// and `nextCandidates` below — and roughly twenty test constructions each
    /// had to state an answer before this built, and so will the fifth. The
    /// template is `providedFollowUps`, whose two sites diverge deliberately.
    ///
    /// ⚠️ **`method` arrived defaulted and was the case this paragraph
    /// predicted.** It shipped as `method: MethodResolution =
    /// MethodCatalog.resolve(nil)` on the reasoning that omitting it asserts
    /// `.unset(ai-migration-kit)` — a real state, the commonest one, and what
    /// every board did before packs. That reasoning is sound about the *value*
    /// and beside the point about the *parameter*: an independent review deleted
    /// the argument from `nextCandidates` and, separately, from
    /// `AppModel.preview` — the two lines whose own comments say that omitting
    /// them **is** the defect this field exists to fix — and the full suite
    /// stayed green at 1840/1840 both times. Only `BoardService.proposeMove` was
    /// pinned. A default cannot catch the next caller; that is the whole content
    /// of the rule, and it does not bend for a value that happens to be common.
    public init(
        repoIsEnabled: Bool = true,
        repoPreflight: PreflightState = .notChecked,
        method: MethodResolution,
        activeRunID: UUID? = nil,
        allowSideEffects: Bool = true,
        providedFollowUps: [String]? = nil,
        requiresVerifiedGreen: Bool,
        prVerdict: ResolvedPRStatus?
    ) {
        self.repoIsEnabled = repoIsEnabled
        self.repoPreflight = repoPreflight
        self.method = method
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
