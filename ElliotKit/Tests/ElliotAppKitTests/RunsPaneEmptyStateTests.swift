import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// What the Runs pane says when nothing has run.
///
/// At three spans this pane is half the panel, and drawn blank it read as
/// broken rather than as "nothing has run yet" — the same failure an empty
/// column had before `ColumnView.dropHint`.
///
/// The thing worth testing is not the wording; it is that the wording is
/// **derived**. `Column.naturalNext` says where the card goes next and
/// `Consequence.of` says what arriving there does, and both are read from
/// `evaluateMove` — the pure function `BoardService` actually commits with. A
/// hand-written sentence per column would be a third copy of the transition
/// matrix, and it would go on offering to file an issue for a card whose
/// repository is switched off. So most of what follows compares the copy back
/// to the machinery it came from rather than to a string literal.
@Suite("Runs pane empty state")
struct RunsPaneEmptyStateTests {

    /// The outcome each column's natural next move actually produces for a
    /// healthy card, straight out of the rule engine's own vocabulary.
    private let healthy: [ElliotModel.Column: MoveOutcome] = [
        .backlog: .action(.createIssue(idea: "As a reader, I want an empty state…")),
        .todo: .action(.implementIssue(issueNumber: 79)),
        // In Progress → In Review is the one permitted move that starts
        // nothing: Elliot fills that column itself.
        .inProgress: .noAction,
        .inReview: .needsInput(.followUps(prNumber: 88)),
    ]

    // MARK: - 1. Every column gets a sentence, and it is about that column

    @Test("Every column produces a title and a message, and neither is empty")
    func nothingRendersBlank() {
        for column in ElliotModel.Column.allCases {
            let copy = RunsPane.emptyState(column: column, outcome: healthy[column])
            #expect(!copy.title.isEmpty)
            #expect(!copy.message.isEmpty)
            #expect(copy.message.hasSuffix("."), "Copy: \(copy.message)")
        }
    }

    /// The whole point of the change: the sentence has to be true for the card
    /// in question, so it must name where *this* card goes next.
    @Test("A card that can advance is told which move would produce a run")
    func theMessageNamesTheNextColumn() {
        for column in ElliotModel.Column.allCases {
            guard let next = column.naturalNext else { continue }
            let copy = RunsPane.emptyState(column: column, outcome: healthy[column])
            #expect(
                copy.message.contains(next.displayName),
                "\(column.displayName) should point at \(next.displayName): \(copy.message)"
            )
        }
    }

    // MARK: - 2. The copy is the machinery's own words

    /// Not "the message mentions issues" — the message *ends with the
    /// consequence's own summary*, the same sentence the column caption and the
    /// next-step button already show. That is what makes it impossible for the
    /// empty state to describe a move the rule engine would decide differently.
    @Test("A move that starts something quotes the consequence verbatim")
    func theMessageIsTheConsequencesOwnSentence() {
        for (column, outcome) in healthy {
            guard case .noAction = outcome else {
                let copy = RunsPane.emptyState(column: column, outcome: outcome)
                #expect(
                    copy.message.hasSuffix(Consequence.of(outcome).summary),
                    """
                    \(column.displayName) should end with the column caption's own \
                    words, not a second phrasing of them: \(copy.message)
                    """
                )
                continue
            }
        }
    }

    /// The specific sentences, as a reader sees them. Pinned so a change to
    /// them is a decision rather than a side effect — the assertions above pin
    /// the *derivation*, this one pins the result.
    @Test("Backlog, To Do and In Review each name their own run")
    func theThreeRunProducingColumns() {
        #expect(
            RunsPane.emptyState(column: .backlog, outcome: healthy[.backlog]).message
                == "Move it to To Do to start the first run. Files a GitHub issue."
        )
        #expect(
            RunsPane.emptyState(column: .todo, outcome: healthy[.todo]).message
                == "Move it to In Progress to start the first run. "
                + "Implements #79 and opens a pull request."
        )
        #expect(
            RunsPane.emptyState(column: .inReview, outcome: healthy[.inReview]).message
                == "Move it to Done to start the first run. "
                + "Asks for follow-ups, then merges PR 88."
        )
    }

    // MARK: - 3. The three states that are not "move it and it runs"

    /// In Progress → In Review is permitted and starts nothing. Saying only
    /// "nothing runs" would leave a reader with no idea what does, so the
    /// destination's own standing rule finishes the sentence.
    @Test("A permitted move that starts nothing says so, and says who does move the card")
    func theMoveThatRunsNothing() {
        let copy = RunsPane.emptyState(column: .inProgress, outcome: .noAction)
        #expect(copy.title == "Nothing has run yet")
        #expect(copy.message.contains("Nothing runs on the way to In Review."))
        #expect(
            copy.message.hasSuffix(ElliotModel.Column.inReview.standingRule),
            "The destination's standing rule is the answer, not a second copy of it: \(copy.message)"
        )
        #expect(!copy.message.contains("start the first run"))
    }

    /// A refused move already names the gap rather than the rule — "No issue
    /// yet — file it in To Do first" — so it is repeated verbatim. What it must
    /// never do is promise a run: the move cannot be made.
    @Test("A refused move is stated, never dressed up as a run waiting to happen")
    func theRefusedMove() {
        // Every case except `.sameColumn`, from the compiler-checked shadow.
        // `.sameColumn` is excluded because this pane only ever previews
        // `naturalNext`, so a card cannot be refused here for being where it
        // already is — an exclusion by name, not a list that can fall behind.
        let blocks = MoveBlockCase.allCases
            .filter { $0 != .sameColumn }
            .map(\.sample)

        for block in blocks {
            let outcome = MoveOutcome.blocked(block)
            let copy = RunsPane.emptyState(column: .todo, outcome: outcome)

            #expect(copy.title == "Nothing has run yet")
            #expect(copy.message.hasPrefix("Moving it to In Progress is refused."))
            #expect(
                copy.message.hasSuffix(Consequence.reason(block)),
                "The refusal names the gap in the rule engine's own words: \(copy.message)"
            )
            #expect(
                !copy.message.contains("start the first run"),
                "A refused move must not be offered as the way to start one."
            )
        }
    }

    /// Done has no `naturalNext`, so there is no move to preview and no run to
    /// promise. "Nothing has run *yet*" would be a promise, so the title
    /// changes too — this is a different state, not a different phrasing.
    @Test("Done gets its own title as well as its own sentence")
    func theEndOfTheBoard() {
        let copy = RunsPane.emptyState(column: .done, outcome: nil)

        #expect(copy.title == "No runs recorded")
        #expect(copy.message == "Done is the end of the board — nothing runs from here.")
        #expect(!copy.message.contains("yet"))

        // And it is the only column that gets it, read off `naturalNext` rather
        // than off a list of exclusions.
        let terminal = ElliotModel.Column.allCases.filter { $0.naturalNext == nil }
        #expect(terminal == [.done])
        for column in ElliotModel.Column.allCases where column != .done {
            #expect(
                RunsPane.emptyState(column: column, outcome: healthy[column]).title
                    == "Nothing has run yet"
            )
        }
    }

    // MARK: - 4. It never says a column is the end of the board when it is not

    /// The branch is chosen by `naturalNext`, never by whether an outcome was
    /// supplied. Those were one `guard` briefly, and that version answered
    /// "Backlog is the end of the board" to a `nil` outcome — false, and
    /// reachable by a caller that simply had nothing to preview.
    @Test("Only a terminal column is ever called the end of the board")
    func aMissingOutcomeIsNotTheEndOfTheBoard() {
        for column in ElliotModel.Column.allCases {
            let copy = RunsPane.emptyState(column: column, outcome: nil)

            guard let next = column.naturalNext else {
                #expect(copy.title == "No runs recorded")
                #expect(copy.message.contains("the end of the board"))
                continue
            }

            #expect(copy.title == "Nothing has run yet")
            #expect(
                !copy.message.contains("the end of the board"),
                "\(column.displayName) has a next column; it is not the end of anything."
            )
            #expect(copy.message.contains(next.displayName))
            // It names the move and claims nothing about what the move does,
            // because with no outcome in hand it does not know.
            #expect(!copy.message.contains("Files"))
            #expect(!copy.message.contains("refused"))
        }
    }
}
