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

    /// How many rows a folded band draws before the disclosure takes over.
    ///
    /// Three, which is what the Operations band drew before it could act. The
    /// number is not the point; having exactly one of it is — the count in the
    /// disclosure's label and the rows it reveals are now derived from the same
    /// constant instead of being written at two call sites.
    public static let bandLimit = 3

    /// The rows a band draws, and the ones the disclosure is holding back.
    ///
    /// ⛔ **Reorders nothing, re-decides nothing, drops nothing.** `steps` arrives
    /// ordered by `rankNextSteps` and already narrowed by `nextStepsWindow`; this
    /// takes a prefix and counts the remainder, so `shown.count + folded ==
    /// steps.count` always holds. That equality is the whole reason this is a
    /// function here rather than a `prefix(3)` in a view: the number a reader is
    /// offered and the rows they get for pressing it cannot be computed from two
    /// different lists.
    ///
    /// That is not a hypothetical. The Operations band pressed *"See all N"* with
    /// `N` counted off `AppModel.nextSteps` — the whole board, unfiltered — and
    /// opened a screen rendering `nextStepsView`, which is filtered by repository
    /// and by the blocked toggle. With a filter set, "See all 12" opened a list of
    /// four, and nothing in either place was wrong on its own.
    public func band(expanded: Bool, limit: Int = NextStepsWindow.bandLimit) -> NextStepsBand {
        guard !expanded, steps.count > limit else {
            return NextStepsBand(shown: steps, folded: 0, limit: limit)
        }
        return NextStepsBand(
            shown: Array(steps.prefix(limit)), folded: steps.count - limit, limit: limit)
    }
}

/// What a band draws of a `NextStepsWindow`, and what pressing its disclosure
/// would add.
///
/// Two withholdings can be in force at once and they are **not** the same fact:
/// `NextStepsWindow.hiddenBlocked` counts rows the reader's own filter or the
/// blocked cap removed from the ranking, and `folded` counts rows the band is
/// keeping behind a disclosure one press away. Saying either number for the other
/// would tell a reader to press something that cannot bring those rows back.
public struct NextStepsBand: Sendable, Equatable {
    /// The rows to draw, in `rankNextSteps`' order.
    public var shown: [NextStep]
    /// Rows behind the disclosure. Zero when the band is drawing everything.
    public var folded: Int
    /// How many rows this band draws when folded.
    ///
    /// Carried rather than left behind so that `canFold` can be **derived**. An
    /// expanded band holds `folded == 0` and is otherwise indistinguishable from
    /// a short one, so without the limit a caller would have to ask the window a
    /// second question to find out whether the disclosure is worth drawing — and
    /// two questions is two answers that can disagree.
    public var limit: Int

    public init(shown: [NextStep], folded: Int, limit: Int) {
        self.shown = shown
        self.folded = folded
        self.limit = limit
    }

    /// Every row of the window this band was taken from.
    public var total: Int { shown.count + folded }

    /// Whether the disclosure has anything to do, in **either** direction.
    ///
    /// ⛔ Not the same question as `isFolded`, and using that one for both is a
    /// control that does nothing. A reader who expands a nine-row ranking and
    /// then filters it down to two leaves `expanded` true: `isFolded` is false,
    /// so *"Show fewer"* would be offered on a list with nothing to fold away,
    /// and pressing it would change the screen not at all.
    public var canFold: Bool { total > limit }

    /// Whether it is currently holding rows back.
    public var isFolded: Bool { folded > 0 }
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
