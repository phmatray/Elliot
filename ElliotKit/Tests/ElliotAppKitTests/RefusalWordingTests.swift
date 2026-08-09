import ElliotIPC
import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// The two hand-written phrasings of every refusal, linked.
///
/// `Consequence.reason` addresses whoever is looking at the board;
/// `MoveBlockText.explain` addresses an agent reading `board_move_card`'s
/// answer. They live in two targets, they are written by hand, and nothing held
/// them together — so "one of them says something and the other does not" was
/// invisible, and so was "someone unified them".
///
/// The direction asserted is **non-identity**, the template being
/// `MoveHistoryTests.historyLabelNeverConvergesWithArrivalNote`: two registers,
/// two audiences, and the day someone collapses them this fails. Containment is
/// checked both ways, because that is how one would end up reading as the other.
///
/// `ElliotAppKitTests` is where this can live at all: `ElliotAppKit` depends on
/// `ElliotIPC`, so this is the only test target that sees both wordings.
@Suite("Refusal wording")
struct RefusalWordingTests {

    @Test("Every block is worded in both places, and neither wording is empty")
    func everyBlockIsWordedTwice() {
        for block in MoveBlockCase.allBlocks {
            #expect(!Consequence.reason(block).isEmpty, "\(block.code) has no board wording")
            #expect(!MoveBlockText.explain(block).isEmpty, "\(block.code) has no wire wording")
        }
    }

    @Test("The board's wording and the wire's wording never converge")
    func theTwoWordingsStayApart() {
        for block in MoveBlockCase.allBlocks {
            let board = Consequence.reason(block)
            let wire = MoveBlockText.explain(block)
            #expect(board != wire, "\(block.code)")
            #expect(!board.contains(wire), "\(block.code): the wire's sentence is inside the board's")
            #expect(!wire.contains(board), "\(block.code): the board's sentence is inside the wire's")
        }
    }

    @Test("A green refusal states the reading it was refused on, in PRSign's own words")
    func notVerifiedGreenQuotesTheSign() {
        // The sentence is written once, from `PRSign.summary`, which already
        // says the right thing for all eight signs. A second table of eight
        // sentences here is what this asserts against.
        let failing = PRSign.checksFailing(count: 3)
        #expect(Consequence.reason(.notVerifiedGreen(reason: .sign(failing))).contains(failing.summary))
        #expect(MoveBlockText.explain(.notVerifiedGreen(reason: .sign(failing))).contains(failing.summary))
    }

    @Test("The four reasons a pull request is not verified green are never the same sentence")
    func notVerifiedGreenReasonsAreMutuallyDistinguishable() {
        // `NotGreenReason` exists because `isMergeableUnattended` refuses two
        // states — `.unstable`, and "the only greens are analysers" — exactly
        // where `PRSign` reads `nil`, the same `nil` that means "nothing was
        // read". A reader must be able to tell all four apart: never read,
        // read-but-failing, read-but-unstable, read-clean-but-analysers-only.
        let reasons: [NotGreenReason] = [
            .noReading,
            .sign(.checksFailing(count: 3)),
            .notClean(.unstable),
            .noBuildVerdict,
        ]
        let boardSentences = reasons.map { Consequence.reason(.notVerifiedGreen(reason: $0)) }
        let wireSentences = reasons.map { MoveBlockText.explain(.notVerifiedGreen(reason: $0)) }

        #expect(boardSentences.allSatisfy { !$0.isEmpty })
        #expect(wireSentences.allSatisfy { !$0.isEmpty })
        #expect(Set(boardSentences).count == reasons.count, "two reasons share a board sentence")
        #expect(Set(wireSentences).count == reasons.count, "two reasons share a wire sentence")

        // `.noReading` is its own answer — nothing was read, which is not a
        // sign, not an unstable merge, and not a clean merge with no build.
        let unreadBoard = Consequence.reason(.notVerifiedGreen(reason: .noReading))
        let unreadWire = MoveBlockText.explain(.notVerifiedGreen(reason: .noReading))
        for sign in [PRSign.conflict, .noBuild, .unknown] {
            #expect(!unreadBoard.contains(sign.summary), "an unread pull request borrowed \(sign.code)")
            #expect(!unreadWire.contains(sign.summary), "an unread pull request borrowed \(sign.code) on the wire")
        }

        // `.notClean` and `.noBuildVerdict` each name the fact that made them
        // true, not a generic "not green" — verified by the `MergeState.code`
        // actually appearing, rather than by guessing at prose.
        #expect(Consequence.reason(.notVerifiedGreen(reason: .notClean(.unstable))).contains(MergeState.unstable.code))
        #expect(MoveBlockText.explain(.notVerifiedGreen(reason: .notClean(.unstable))).contains(MergeState.unstable.code))
    }

    @Test("Every case has a distinct wire code")
    func codesAreDistinct() {
        // Proves the shadow above is not standing two cases on one value: a
        // duplicate here means `allBlocks` is short of the enum.
        let codes = MoveBlockCase.allBlocks.map(\.code)
        #expect(Set(codes).count == codes.count)
        #expect(MoveBlockCase.allCases.allSatisfy { MoveBlockCase.of($0.sample) == $0 })
        #expect(codes.contains("not_verified_green"))
        #expect(codes.contains("system_owned_transition"))
    }
}
