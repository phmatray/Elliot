import Foundation

/// What an unattended session does about one card, this round.
///
/// Pure: no I/O, no clock, no randomness. The clock is a parameter, the idiom of
/// `PRStatus.resolved(now:currentHeadOid:)` — "the clock, passed in so this stays pure" — which is
/// what lets the whole table be driven by hand.
///
/// It decides by reading a `MoveOutcome` that `evaluateMove` produced, never by re-deriving one.
/// The board predicts its own behaviour; this interprets the prediction.
///
/// ⚠️ **This policy can never produce `.settle(.merged, …)`, and that is correct — not a gap.** It
/// sees only a `MoveOutcome`, which is a *proposal* about what a move would do; *merged* is a fact
/// only `gh` establishes, once the pull request actually lands, by a caller that watches it (see
/// `Disposition`'s own doc and `VerifiedOutcome.applied(to:attribution:)`). Applying this
/// repository's central invariant one layer over: **`gh` is the fact; the agent's prose is a
/// hint** — and here, `evaluateMove`'s prediction is the hint. If a later reader goes looking for a
/// `.merged` path in this file, there is not one to find; the merge is recorded elsewhere, by the
/// thing that actually observed it.
public enum AutoDevPolicy {

    public static func disposition(
        outcome: MoveOutcome,
        attempts: Int,
        maxAttempts: Int,
        unchangedSince: Date,
        patience: TimeInterval,
        now: Date
    ) -> Disposition {
        switch outcome {
        case .action, .noAction:
            // `.noAction` is a real advance — a card already filed moving from Backlog to To Do,
            // for one — and it spawns nothing, so it costs no attempt. `attempts` counts runs
            // started, not rounds taken.
            guard attempts < maxAttempts else {
                return .settle(
                    .blocked,
                    reason: "Tried \(attempts) time\(attempts == 1 ? "" : "s") without landing "
                        + "this card.")
            }
            return .retry

        case .needsInput:
            // `NeedsInput` is documented as information "only a human (or an explicit tool
            // argument) can supply". A loop with nobody watching can only read that as "blocked, I
            // will try again" — which is a spin. PR1 makes this unreachable under
            // `requiresVerifiedGreen`; this is the belt, and it settles rather than waits.
            return .settle(
                .blocked, reason: "This move asked for something only a person can supply.")

        case .blocked(let block):
            return decide(block: block, unchangedSince: unchangedSince, patience: patience, now: now)
        }
    }

    /// A run the scheduler is holding, bounded by the same window as a wait.
    ///
    /// The design bounds `.wait`; `.held` needs the same bound for the same reason, and for one
    /// case in particular: `.mergeWaitsForRepoToBeIdle` is exactly the refusal a session that keeps
    /// its own repository busy can leave standing for ever.
    public static func held(
        _ refusal: QueueRefusal,
        unchangedSince: Date,
        patience: TimeInterval,
        now: Date
    ) -> Disposition {
        guard now.timeIntervalSince(unchangedSince) < patience else {
            return .settle(.blocked, reason: expired(refusal.sentence, patience: patience))
        }
        return .held(refusal)
    }

    // MARK: - The table

    /// No `default:` — a thirteenth `MoveBlock` case must fail to compile here, not fall through
    /// to a card silently reported as still engaged.
    private static func decide(
        block: MoveBlock,
        unchangedSince: Date,
        patience: TimeInterval,
        now: Date
    ) -> Disposition {
        switch block {
        case .sameColumn:
            // Unreachable through `naturalNext`, which never proposes the column a card is
            // already in — and a `.wait` here would spin.
            return .settle(.blocked, reason: "This card has nowhere further to go.")

        case .emptyIdea:
            return .settle(.blocked, reason: "There is nothing on this card to file.")

        case .incompleteStory:
            return .settle(
                .blocked,
                reason: "The story is missing one of role, want or benefit, and no amount of "
                    + "repetition completes it.")

        case .missingIssueNumber:
            return waiting("The issue has not been filed yet.", unchangedSince, patience, now)

        case .missingPRNumber:
            return waiting(
                "The pull request has not been opened yet.", unchangedSince, patience, now)

        case .repoDisabled:
            return .abortSession(
                reason: "The repository is disabled in Elliot, so nothing in this session can run.")

        case .repoBlocked:
            return .abortSession(
                reason: "A Preflight check is failing for this repository, so nothing in this "
                    + "session can run.")

        case .unknownMethod(let id):
            // Per-repository, not per-card: `evaluateMove` blocks every transition on this one
            // (`RuleEngine.swift:311`), including the ones that run nothing, so every card in the
            // session fails identically. Belongs beside `repoDisabled`/`repoBlocked`.
            return .abortSession(
                reason: "The repository declares method \"\(id)\", which this build's catalogue "
                    + "does not carry, so nothing in this session can run.")

        case .methodHasNoStep(let method, let kind):
            // Per-transition, and explicitly not a defect (`RuleEngine.swift:375-379` — the
            // shipped BMAD pack carries no steps at all, GSD declares only its first). Another
            // card in the same repository, at another column, may still move, so this settles the
            // one card rather than aborting the whole session.
            return .settle(
                .blocked,
                reason: "The \(method) method declares no step for \(kind), so this card cannot "
                    + "move through it.")

        case .runAlreadyInFlight:
            return waiting("A run is already working on this card.", unchangedSince, patience, now)

        case .notVerifiedGreen(let reason):
            return notGreen(reason, unchangedSince, patience, now)

        case .systemOwnedTransition:
            return .settle(
                .blocked,
                reason: "This step belongs to Elliot's pull-request watcher, not to the session. "
                    + "Waiting cannot fix a category error.")
        }
    }

    /// No `default:` over `NotGreenReason`, and none over the `PRSign` nested inside `.sign` — a
    /// new case in either must fail to compile here.
    private static func notGreen(
        _ reason: NotGreenReason,
        _ unchangedSince: Date,
        _ patience: TimeInterval,
        _ now: Date
    ) -> Disposition {
        switch reason {
        case .noReading:
            return waiting(
                "Nothing has been read yet, and PRWatcher will read it.",
                unchangedSince, patience, now)

        case .sign(let sign):
            // ⛔ Every arm below renders `sign.summary` verbatim, never a sentence composed here —
            // load-bearing across tasks: Task 15's `aNoChecksPullRequestSettlesBlocked` asserts
            // `PRSign.noBuild.summary` against exactly this arm.
            switch sign {
            case .checksRunning, .unknown:
                return waiting(sign.summary, unchangedSince, patience, now)
            case .conflict, .checksFailing, .changesRequested, .reviewRequired, .mergeBlocked,
                .noBuild:
                return .settle(.blocked, reason: sign.summary)
            }

        case .notClean(let merge):
            // Verified against `PRStatus.sign(ci:merge:review:)` (`PRStatus.swift:309-319`) rather
            // than assumed: `.unstable` is the only `MergeState` that can reach this arm with
            // `sign == nil` — every other value signs on its own before `merge` is asked whether
            // it is `.clean` (`.conflict` → `.conflict`; `.blocked`/`.behind` → `.mergeBlocked`;
            // `.unknown` → `.unknown`), and `NotGreenReason.of`'s own guard already excludes
            // `.clean`. Binding `merge` rather than assuming `.unstable` keeps this arm correct if
            // a future `MergeState` case ever changes that.
            return waiting(
                "GitHub does not yet consider this pull request clean to merge (\(merge.code)).",
                unchangedSince, patience, now)

        case .noBuildVerdict:
            return .settle(
                .blocked,
                reason: "Everything known about this pull request is fine and it still cannot be "
                    + "merged unattended — every check that passed is an analyser, never a build, "
                    + "and no amount of waiting produces one that is not configured.")
        }
    }

    private static func waiting(
        _ reason: String, _ unchangedSince: Date, _ patience: TimeInterval, _ now: Date
    ) -> Disposition {
        guard now.timeIntervalSince(unchangedSince) < patience else {
            return .settle(.blocked, reason: expired(reason, patience: patience))
        }
        return .wait(reason: reason)
    }

    /// Seconds, not minutes: a patience of 30 rendered as `0 minutes` is a sentence that reads as a
    /// bug in the sentence.
    private static func expired(_ reason: String, patience: TimeInterval) -> String {
        "\(reason) Nothing changed for \(Int(patience)) seconds, so the session gave up on it."
    }
}
