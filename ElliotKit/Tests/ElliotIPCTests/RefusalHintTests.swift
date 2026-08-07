// Plain `import`, deliberately, where this target's neighbours use `@testable`:
// the whole point of these words is that two *other* targets read them, so the
// test has to see exactly what `ElliotEngine` and `ElliotMCPKit` see. Under
// `@testable` an internal `RefusalHint` would satisfy this suite and fail both
// consumers — which is the one mistake a test of a shared constant can make.
import ElliotIPC
import Testing

@Suite("Refusal hints")
struct RefusalHintTests {

    /// Pinned as a literal rather than compared to itself.
    ///
    /// The text is the interface here: an agent reads it and picks its next
    /// call from it, so a rename that silently changed the tool it names would
    /// be a behaviour change wearing the clothes of a refactor.
    ///
    /// Restored verbatim, and the provenance is worth stating exactly because
    /// the obvious guess is wrong: the string never lived in
    /// `OfflineResponder.swift` — that file was *created* by #144 — but in
    /// `ElliotMCPKit/Tools/ListRunsTool.swift:113`, added by `c372f99` (#20)
    /// and removed by `39b977e` (#144). `git log -S` over `OfflineResponder`
    /// returns nothing, so a reader checking a comment that named it would
    /// conclude the words were invented rather than recovered.
    @Test("card_not_found points at the tool that lists card ids")
    func cardNotFoundNamesListCards() {
        #expect(RefusalHint.cardNotFound == "board_list_cards lists the cards this board holds.")
    }
}
