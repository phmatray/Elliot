import Foundation
import Testing

@testable import ElliotModel

/// One step in either direction, or the reason there is none.
///
/// `⌘→` on a Done card was *enabled*, did nothing, and left no mark: the
/// keyboard path — the only path for someone who cannot drag — returned silently
/// where a drop would have written a refusal on the card.
@Suite("Column step")
struct ColumnStepTests {

    @Test(
        "Forward walks the board in order",
        arguments: [
            (Column.backlog, Column.todo),
            (Column.todo, Column.inProgress),
            (Column.inProgress, Column.inReview),
            (Column.inReview, Column.done),
        ]
    )
    func forwardStepsOne(from: Column, to: Column) {
        #expect(from.step(forward: true) == .to(to))
    }

    @Test(
        "Backward walks it the other way",
        arguments: [
            (Column.done, Column.inReview),
            (Column.inReview, Column.inProgress),
            (Column.inProgress, Column.todo),
            (Column.todo, Column.backlog),
        ]
    )
    func backwardStepsOne(from: Column, to: Column) {
        #expect(from.step(forward: false) == .to(to))
    }

    /// The two cases the silent `return` covered.
    @Test("Each end of the board refuses, and names itself")
    func theEndsRefuseWithAReason() {
        guard case .atEdge(let last) = Column.done.step(forward: true) else {
            Issue.record("advancing from Done should be refused")
            return
        }
        guard case .atEdge(let first) = Column.backlog.step(forward: false) else {
            Issue.record("moving back from Backlog should be refused")
            return
        }
        #expect(last.contains("Done"))
        #expect(last.contains("advance"))
        #expect(first.contains("Backlog"))
        #expect(first.contains("move back"))
    }

    /// A refusal with no reason is only a quieter way of doing nothing.
    @Test("No refusal is ever an empty sentence")
    func everyRefusalSaysSomething() {
        for column in Column.allCases {
            for forward in [true, false] {
                if case .atEdge(let reason) = column.step(forward: forward) {
                    #expect(reason.isEmpty == false)
                    #expect(reason.contains(column.displayName))
                }
            }
        }
    }

    /// ⛔ Read off `allCases`, like `naturalNext` and `boardIndex`, so board
    /// order and this one step cannot come to disagree.
    @Test("Stepping forward agrees with naturalNext, everywhere")
    func forwardAgreesWithNaturalNext() {
        for column in Column.allCases {
            #expect(column.step(forward: true).column == column.naturalNext)
        }
    }

    /// A step and its reverse land back where they started — the property that
    /// would fail first if either direction were written out by hand.
    @Test("Forward then back is where you were")
    func stepsAreReversible() {
        for column in Column.allCases {
            guard let next = column.step(forward: true).column else { continue }
            #expect(next.step(forward: false).column == column)
        }
    }
}
