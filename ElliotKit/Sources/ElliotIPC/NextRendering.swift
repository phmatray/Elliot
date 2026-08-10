import ElliotModel
import Foundation

/// What a refused move is called, in words.
///
/// One implementation because two paths answer the same question: the running
/// app renders `board_next` and `board_move_card`, the helper renders
/// `board_next` from a snapshot. The machine-readable half — `MoveBlock.code` —
/// was already shared and could not drift. The prose was written twice and had:
/// one copy said "Set role, want and benefit on the card", the other named the
/// tool that does it. Only one of those helps an agent.
public enum MoveBlockText {
    public static func explain(_ block: MoveBlock) -> String {
        switch block {
        case .sameColumn: "The card is already in that column."
        case .emptyIdea: "The card has no story, title or body to file as an issue."
        case .incompleteStory: "The story is missing one of role, want or benefit."
        case .missingIssueNumber: "The card has no issue number."
        case .missingPRNumber: "The card has no pull request number."
        case .repoDisabled: "That repository is disabled in Elliot."
        case .repoBlocked:
            "Elliot's Preflight checks are failing for that repository, so no card in it "
                + "can be moved. Moving one would start an unattended run inside a checkout "
                + "Elliot has already diagnosed as broken."
        case .unknownMethod(let id):
            "That repository is set to the method \"\(id)\", which this build has no pack for. "
                + "Nothing can move there until it names a method Elliot knows — running some "
                + "other method's commands instead is exactly what this refusal prevents."
        case .methodHasNoStep(let method, let kind):
            "The \(method) method declares no \(kind) step, so this move has nothing to run. "
                + "That is by design for some methods rather than a fault: this transition is "
                + "simply not wired for it in wave 1."
        case .runAlreadyInFlight(let runID): "A run (\(runID)) is already working on this card."
        case .notVerifiedGreen(let reason):
            "This move requires a verified green build. " + Self.notGreenPhrase(reason)
        case .systemOwnedTransition:
            "That transition has one owner: Elliot makes it when the pull request goes ready."
        }
    }

    /// The reason named for each `NotGreenReason`, in the wire's own words.
    ///
    /// A separate phrasing from `Consequence.notGreenGap`'s, on purpose — see
    /// that function's doc. `.sign` is the one case both voices quote
    /// verbatim, because `PRSign.summary` is the one sentence, written once.
    private static func notGreenPhrase(_ reason: NotGreenReason) -> String {
        switch reason {
        case .noReading:
            "No reading of the pull request."
        case .sign(let sign):
            sign.summary
        case .notClean(let state):
            "The merge state is \(state.code), not clean."
        case .noBuildVerdict:
            "Every passing check is a non-build analyser."
        }
    }

    /// The gesture that clears the block, named as a tool the agent can call.
    public static func hint(_ block: MoveBlock) -> String? {
        switch block {
        case .missingIssueNumber:
            "Move it backlog → todo first, which files the issue."
        case .missingPRNumber:
            "Move it todo → inProgress first, which opens the pull request."
        case .incompleteStory:
            "Set role, want and benefit with board_update_card."
        case .runAlreadyInFlight:
            "Wait for it to finish: board_await_run holds until it does."
        case .repoDisabled:
            "Enable the repository in Elliot's Preflight screen."
        case .repoBlocked:
            // Names the screen rather than a tool, because there is no tool: the
            // remedies are things like re-registering the main checkout or
            // committing a repo profile, which happen outside Elliot. Saying
            // "run Preflight again" would be worse than saying nothing — it
            // suggests the reading is stale when the usual case is that it is
            // correct.
            "Open Elliot's Preflight screen to see which check is failing, and repair it there."
        case .unknownMethod:
            // A screen again rather than a tool: the id came from a human choice
            // (or, in wave 3, a committed settings file), and the menu that can
            // change it is the only thing that can clear this.
            "Choose a method Elliot knows on its Repositories page."
        case .methodHasNoStep:
            // Deliberately offers the *other* way out too. Unlike every block
            // above, this one may never clear for this method — waiting is not a
            // remedy, and an agent told only "choose another method" would keep
            // retrying a card the reader may simply want moved back.
            "Choose a method that declares this step, or move the card back."
        case .notVerifiedGreen:
            "Wait for the checks, or make the move yourself — a move a person makes is not "
                + "held to a verified green."
        case .systemOwnedTransition:
            "Nothing to do here. Elliot makes this move itself once the pull request is ready."
        case .sameColumn, .emptyIdea:
            nil
        }
    }
}

public extension NextDTO {
    /// Renders one ranked step for the wire.
    ///
    /// Here rather than in either caller because both of them render it, and the
    /// two copies disagreed: the helper's told every `.noAction` card that
    /// "Elliot moves this card itself when it notices the pull request is
    /// ready", which is false for a backlog card that already carries an issue
    /// number — nothing is watching a pull request that does not exist, and an
    /// agent that believed the sentence would stop. Two renderings of one
    /// question is one too many.
    init(step: NextStep, rank: Int, activeRunID: UUID?) {
        let card = CardDTO(card: step.card, repoName: step.repoName, activeRunID: activeRunID)
        let label = "\(step.card.displayTitle) (\(step.repoName))"
        let move = "\(step.card.column.displayName) → \(step.to.displayName)"

        switch step.outcome {
        case .action(let action):
            self.init(
                card: card, nextColumn: step.to.rawValue,
                wouldTrigger: action.kind.skillName, isReady: true, rank: rank,
                summary: "\(label) is ready: move it \(move) to run \(action.kind.skillName)."
            )

        case .noAction:
            // Two shapes reach here and they are not the same news: work in
            // flight that Elliot advances on its own, and a card already
            // carrying what the move would have produced.
            let waitingOnElliot = step.card.column == .inProgress
            self.init(
                card: card, nextColumn: step.to.rawValue, isReady: false,
                blockCode: NextBlockCode.nothingToTrigger,
                blockReason: waitingOnElliot
                    ? "Elliot moves this card itself when it notices the pull request is ready."
                    : "The move is allowed but runs nothing: the card already carries what it "
                        + "would have produced.",
                blockHint: waitingOnElliot
                    ? "Nothing to do here. board_await_run follows the run that is open on it."
                    : nil,
                rank: rank,
                summary: waitingOnElliot
                    ? "\(label) is in flight; Elliot makes the \(move) move itself."
                    : "\(label) can go \(move), but nothing would run."
            )

        case .needsInput(.followUps(let prNumber)):
            // Unreachable while candidates are evaluated with an empty follow-up
            // list, which is what makes a merge readable as ready. Kept because
            // the outcome type allows it and silence would be the worse failure.
            self.init(
                card: card, nextColumn: step.to.rawValue,
                wouldTrigger: SkillKind.mergePR.skillName, isReady: false,
                blockCode: NextBlockCode.needsInput,
                blockReason: "Merging pull request #\(prNumber) needs a follow-up list.",
                blockHint: "Move it with follow_ups: [] to merge and file nothing.",
                rank: rank,
                summary: "\(label) is waiting on a follow-up list before \(move)."
            )

        case .blocked(let block):
            let reason = MoveBlockText.explain(block)
            self.init(
                card: card, nextColumn: step.to.rawValue, isReady: false,
                blockCode: block.code,
                blockReason: reason,
                blockHint: MoveBlockText.hint(block),
                rank: rank,
                summary: "\(label) cannot go \(move): \(reason)"
            )
        }
    }
}
