import Foundation
import Testing

@testable import ElliotModel

/// The window a reader sees over `rankNextSteps`' answer.
///
/// `board_next` gave an agent a repository argument and a capped limit; the
/// human got every card on every repository, unpaged — a scroll of blocked rows
/// between the reader and the ready ones.
@Suite("Next steps window")
struct NextStepsWindowTests {

    private static let fixed = Date(timeIntervalSince1970: 1_770_000_000)

    private static func step(_ title: String, ready: Bool) -> NextStep {
        NextStep(
            card: Card(
                repoID: UUID(), title: title,
                columnEnteredAt: fixed, createdAt: fixed, updatedAt: fixed
            ),
            repoName: "phmatray/Elliot",
            to: .todo,
            outcome: ready ? .action(.createIssue(idea: title, labels: [])) : .blocked(.repoDisabled)
        )
    }

    private static func board(ready: Int, blocked: Int) -> [NextStep] {
        (0..<ready).map { step("ready \($0)", ready: true) }
            + (0..<blocked).map { step("blocked \($0)", ready: false) }
    }

    @Test("Everything fits, so nothing is hidden")
    func shortBoardIsWhole() {
        let window = nextStepsWindow(Self.board(ready: 2, blocked: 3), showsBlocked: true)
        #expect(window.steps.count == 5)
        #expect(window.hiddenBlocked == 0)
        #expect(window.isCapped == false)
    }

    @Test("Hiding blocked keeps only what a move would actually start")
    func hidingBlockedKeepsReady() {
        let window = nextStepsWindow(Self.board(ready: 2, blocked: 7), showsBlocked: false)
        let everyRowIsReady = window.steps.allSatisfy { $0.isReady }
        #expect(window.steps.count == 2)
        #expect(everyRowIsReady)
        #expect(window.hiddenBlocked == 7)
    }

    @Test("The blocked tail is capped, and the count of what was dropped is exact")
    func blockedTailIsCapped() {
        let window = nextStepsWindow(
            Self.board(ready: 3, blocked: 40), showsBlocked: true, blockedLimit: 10)
        let blockedShown = window.steps.filter { !$0.isReady }.count
        #expect(window.steps.count == 13)
        #expect(blockedShown == 10)
        #expect(window.hiddenBlocked == 30)
        #expect(window.isCapped)
    }

    /// ⛔ The cap must never reach the ready rows — they are the answer, and the
    /// blocked tail is the context that was burying them.
    @Test("A cap smaller than the ready set still keeps every ready row")
    func readyRowsAreNeverCapped() {
        let window = nextStepsWindow(
            Self.board(ready: 25, blocked: 5), showsBlocked: true, blockedLimit: 2)
        let readyShown = window.steps.filter { $0.isReady }.count
        #expect(readyShown == 25)
        #expect(window.hiddenBlocked == 3)
    }

    /// ⛔ A window, never a second ranking. Rebuilding the list as "ready ones,
    /// then blocked ones" gives the same answer today only because readiness is
    /// the sort's first key — and would silently reorder the board the day that
    /// changed. This drives an order that is deliberately *not* grouped.
    @Test("The order it was given is the order it returns")
    func orderIsPreserved() {
        let interleaved = [
            Self.step("a", ready: false),
            Self.step("b", ready: true),
            Self.step("c", ready: false),
            Self.step("d", ready: true),
        ]
        let window = nextStepsWindow(interleaved, showsBlocked: true)
        #expect(window.steps.map(\.card.title) == ["a", "b", "c", "d"])
    }

    @Test("With blocked hidden, the survivors keep their relative order")
    func hidingPreservesOrder() {
        let interleaved = [
            Self.step("a", ready: false),
            Self.step("b", ready: true),
            Self.step("c", ready: false),
            Self.step("d", ready: true),
        ]
        let window = nextStepsWindow(interleaved, showsBlocked: false)
        #expect(window.steps.map(\.card.title) == ["b", "d"])
    }

    @Test("An empty ranking is an empty window, not a capped one")
    func emptyIsNotCapped() {
        let window = nextStepsWindow([], showsBlocked: true)
        #expect(window.steps.isEmpty)
        #expect(window.isCapped == false)
    }

    /// Every row is accounted for exactly once, whatever the settings — a cap
    /// that loses a row without counting it reads as a board with less on it.
    @Test(
        "Shown plus hidden is always the whole ranking",
        arguments: [(true, 10), (true, 0), (false, 10), (false, 3)]
    )
    func nothingIsLost(showsBlocked: Bool, limit: Int) {
        let ranked = Self.board(ready: 4, blocked: 9)
        let window = nextStepsWindow(ranked, showsBlocked: showsBlocked, blockedLimit: limit)
        #expect(window.steps.count + window.hiddenBlocked == ranked.count)
    }

    // MARK: - The band's disclosure (#304)

    /// The property the whole disclosure rests on, and the one its predecessor
    /// did not have.
    ///
    /// *"See all N"* counted `AppModel.nextSteps` — the unfiltered board — and
    /// opened a screen rendering `nextStepsView`, which the repository picker and
    /// the blocked toggle had already narrowed. The number offered and the rows
    /// delivered came from two lists, so with a filter set "See all 12" opened a
    /// list of four. Deriving both from one window is what makes that
    /// unrepresentable rather than merely fixed.
    @Test(
        "The rows drawn plus the rows folded away are the whole window",
        arguments: [0, 1, 3, 4, 13]
    )
    func theBandAccountsForEveryRow(count: Int) {
        let window = nextStepsWindow(Self.board(ready: count, blocked: 0), showsBlocked: true)
        for expanded in [true, false] {
            let band = window.band(expanded: expanded)
            #expect(band.shown.count + band.folded == window.steps.count)
        }
    }

    @Test("A folded band draws the first few and says how many it is holding back")
    func aFoldedBandHoldsTheTailBack() {
        let window = nextStepsWindow(Self.board(ready: 9, blocked: 0), showsBlocked: true)
        let band = window.band(expanded: false)
        #expect(band.shown.count == NextStepsWindow.bandLimit)
        #expect(band.folded == 9 - NextStepsWindow.bandLimit)
        #expect(band.isFolded)
        #expect(band.canFold)
    }

    /// ⛔ `canFold` and `isFolded` are different questions, and the case that
    /// tells them apart is this one: an expanded band holds nothing back and the
    /// disclosure must still be drawn, or the reader has no way back to a glance.
    @Test("An expanded band draws everything, holds nothing back, and can still fold")
    func anExpandedBandDrawsTheWholeRanking() {
        let window = nextStepsWindow(Self.board(ready: 9, blocked: 0), showsBlocked: true)
        let band = window.band(expanded: true)
        #expect(band.shown.count == window.steps.count)
        #expect(band.folded == 0)
        #expect(!band.isFolded)
        #expect(band.canFold)
        #expect(band.total == 9)
    }

    /// A ranking that already fits has no disclosure at all — in either
    /// direction, and whatever the reader last pressed. This is the case that
    /// makes `canFold` derived from the limit rather than read off `isFolded`: a
    /// reader who expands a long list and then filters it short leaves `expanded`
    /// true, and *"Show fewer"* on a two-row band would change nothing.
    @Test("A ranking that fits offers no disclosure, expanded or not")
    func aShortRankingIsNotFolded() {
        let window = nextStepsWindow(
            Self.board(ready: NextStepsWindow.bandLimit, blocked: 0), showsBlocked: true)
        for expanded in [true, false] {
            let band = window.band(expanded: expanded)
            #expect(band.shown.count == NextStepsWindow.bandLimit)
            #expect(!band.isFolded)
            #expect(!band.canFold)
        }
    }

    /// ⛔ The band takes a prefix. It does not partition, sort, or prefer the
    /// ready rows — `rankNextSteps` already put them first, and re-deciding that
    /// here would be the second ranking `NextStepsWindow` exists not to be.
    @Test("The band is a prefix of the window, in the window's own order")
    func theBandIsAPrefixNotASelection() {
        let interleaved = [
            Self.step("a", ready: false),
            Self.step("b", ready: true),
            Self.step("c", ready: false),
            Self.step("d", ready: true),
        ]
        let window = nextStepsWindow(interleaved, showsBlocked: true)
        #expect(window.band(expanded: false, limit: 2).shown.map(\.card.title) == ["a", "b"])
        #expect(window.band(expanded: true).shown.map(\.card.title) == ["a", "b", "c", "d"])
    }
}
