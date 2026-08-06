import ElliotModel
import Testing

@testable import ElliotAppKit

/// Punctuation next to an inline chip, which a code review found detached.
///
/// A `#79` chip followed by a comma laid the comma out as its own flow item, so
/// it could wrap onto the next line on its own or sit 4pt adrift. These pin the
/// fold that keeps it attached — and pin its two limits, because gluing more
/// than flush punctuation breaks emphasis that follows a path.
@Suite("Inline glue")
struct InlineGlueTests {

    @Test("Punctuation flush against a chip is glued to it")
    func punctuationGluesToTheChip() {
        let line = InlineText(runs: [.text("closes "), .issueRef(79), .text(", and more")])
        let pieces = InlineTextView.pieces(of: line, context: .unresolved)

        #expect(pieces == [
            .word("closes", .plain),
            .chip(text: "#79", symbol: "circle.dashed", url: nil),
            .glued(",", .plain),
            .word("and", .plain),
            .word("more", .plain),
        ])

        let items = InlineTextView.items(pieces)
        #expect(items.count == 4)
        #expect(items[1].piece == .chip(text: "#79", symbol: "circle.dashed", url: nil))
        #expect(items[1].glued == [.glued(",", .plain)])
        #expect(items[2].piece == .word("and", .plain))
        #expect(items[2].glued.isEmpty)
    }

    @Test("A full stop after a code span, and a closing bracket, glue too")
    func otherPunctuationGlues() {
        let line = InlineText(runs: [.code("swift test"), .text("). Then more")])
        let pieces = InlineTextView.pieces(of: line, context: .unresolved)
        #expect(pieces == [
            .code("swift test"), .glued(").", .plain), .word("Then", .plain), .word("more", .plain),
        ])
        #expect(InlineTextView.items(pieces).first?.glued == [.glued(").", .plain)])
    }

    @Test("A spaced em dash is nobody's tail")
    func spacedPunctuationStaysItsOwnWord() {
        let line = InlineText(runs: [.path("a/b.swift"), .text(" — see it")])
        let pieces = InlineTextView.pieces(of: line, context: .unresolved)
        #expect(pieces == [
            .chip(text: "a/b.swift", symbol: "doc.text", url: nil),
            .word("—", .plain), .word("see", .plain), .word("it", .plain),
        ])
        #expect(InlineTextView.items(pieces).allSatisfy { $0.glued.isEmpty })
    }

    @Test("A letter flush against a chip is a word, not a tail")
    func lettersAreNotGlued() {
        let line = InlineText(runs: [.path("a/b.swift"), .emphasis("really now")])
        let pieces = InlineTextView.pieces(of: line, context: .unresolved)
        #expect(pieces.suffix(2) == [.word("really", .emphasis), .word("now", .emphasis)])
    }

    @Test("A tail with nothing before it is kept as a word")
    func orphanTailSurvives() {
        let items = InlineTextView.items([.glued(",", .plain), .word("x", .plain)])
        #expect(items == [
            InlineItem(piece: .word(",", .plain)), InlineItem(piece: .word("x", .plain)),
        ])
    }

    @Test("Punctuation carries the style of the run it came from")
    func gluedKeepsItsStyle() {
        let line = InlineText(runs: [.issueRef(4), .strong(", loudly")])
        #expect(InlineTextView.pieces(of: line, context: .unresolved).contains(.glued(",", .strong)))
    }
}
