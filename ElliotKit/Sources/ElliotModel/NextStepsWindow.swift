import Foundation

/// How much of a ranking a reader is actually shown, and what that left out.
///
/// `board_next` gives an agent a `repo` argument and a capped `limit`, and
/// explains both. The human got every card on every registered repository in
/// one unpaged list — on a portfolio board, a scroll of blocked rows sitting
/// between the reader and the ready ones. The screen that exists because "the
/// app computed the answer and gave it only to the robot" was still answering
/// only the robot's question.
///
/// ⛔ **A window, never a second ranking.** `rankNextSteps` decided the order by
/// calling `evaluateMove`, and `isReady` is that verdict — not a judgement made
/// here. This walks the ranked list in the order it arrived and keeps or drops
/// each row; it does not partition, sort, or re-evaluate. Rebuilding the array
/// as "the ready ones, then the blocked ones" would give the same answer today
/// only because readiness happens to be the sort's first key, and would reorder
/// the board in silence the day that changed.
public struct NextStepsWindow: Sendable, Equatable {
    /// The rows to draw, in `rankNextSteps`' order.
    public var steps: [NextStep]
    /// Blocked rows not drawn — hidden by the toggle, or past the cap.
    public var hiddenBlocked: Int

    public init(steps: [NextStep], hiddenBlocked: Int) {
        self.steps = steps
        self.hiddenBlocked = hiddenBlocked
    }

    /// How many blocked rows are worth showing before they stop being context
    /// and start being the scroll they were hiding behind.
    public static let blockedLimit = 10

    /// Whether anything was left out, so a caller cannot render a truncated list
    /// as a complete one. The same discipline as `Spend.isComplete` and
    /// `MoveHistory.isCapped`: a cap that does not announce itself reads exactly
    /// like a board with nothing more on it.
    public var isCapped: Bool { hiddenBlocked > 0 }
}

/// Applies the reader's two choices to a ranking, without re-deciding any of it.
///
/// `showsBlocked == false` keeps only what moving would actually start;
/// otherwise the blocked tail is kept up to `blockedLimit`. Either way
/// `hiddenBlocked` counts exactly what was dropped.
public func nextStepsWindow(
    _ ranked: [NextStep],
    showsBlocked: Bool,
    blockedLimit: Int = NextStepsWindow.blockedLimit
) -> NextStepsWindow {
    var steps: [NextStep] = []
    var keptBlocked = 0
    var hidden = 0
    for step in ranked {
        if step.isReady {
            steps.append(step)
        } else if showsBlocked && keptBlocked < blockedLimit {
            steps.append(step)
            keptBlocked += 1
        } else {
            hidden += 1
        }
    }
    return NextStepsWindow(steps: steps, hiddenBlocked: hidden)
}
