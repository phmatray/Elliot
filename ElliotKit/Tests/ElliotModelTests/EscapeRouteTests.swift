import Foundation
import Testing

@testable import ElliotModel

/// What Escape dismisses, in what order, and — the half that is easy to lose —
/// when it must dismiss nothing at all.
///
/// The route has to agree with the board as it stands today before it is allowed
/// to add a step: `BoardView.onKeyPress(.escape)` deselects a card and otherwise
/// returns `.ignored`, and that fall-through is what lets an open sheet see the
/// key. A rule that reported every press as handled would be green here and
/// would trap a reader inside a sheet.
@Suite("Escape route")
struct EscapeRouteTests {

    // MARK: - 1. Today's behaviour, unchanged

    @Test("With the console shut, Escape does exactly what the board does today")
    func theRouteAgreesWithTheBoardAsItStands() {
        #expect(
            EscapeRoute.next(consoleIsOpen: false, hasSelectedCard: true) == .deselectCard
        )
        #expect(
            EscapeRoute.next(consoleIsOpen: false, hasSelectedCard: false) == .ignored
        )
    }

    /// ⚠️ The property the whole route is worth nothing without: with nothing to
    /// dismiss the press is handed on, so the responder chain still sees it.
    ///
    /// This comment said "so a sheet can still close" until #261, and there is
    /// no sheet in this package to close — zero `.sheet(`, measured. What is
    /// actually down the chain is an inline editor's own `.onExitCommand` and
    /// then the window.
    @Test("Nothing to dismiss means the key is handed on, not swallowed")
    func anEmptyBoardHandsTheKeyOn() {
        let route = EscapeRoute.next(consoleIsOpen: false, hasSelectedCard: false)
        #expect(route == .ignored)
        #expect(
            !route.isHandled,
            """
            reporting an empty board's Escape as handled claims the key for a route that did \
            not use it, and takes it from the responder chain below
            """
        )
    }

    // MARK: - 2. The order

    @Test("The console goes before the selection, and the selection survives it")
    func theConsoleIsDismissedFirst() {
        #expect(
            EscapeRoute.next(consoleIsOpen: true, hasSelectedCard: true) == .foldConsole,
            "the console arrived later and covers more; it is what Escape means while it is open"
        )
    }

    @Test("Two presses fold the console and then clear the selection")
    func thePressesUnwindInOrder() {
        var consoleIsOpen = true
        let hasSelectedCard = true

        let first = EscapeRoute.next(consoleIsOpen: consoleIsOpen, hasSelectedCard: hasSelectedCard)
        #expect(first == .foldConsole)
        consoleIsOpen = false

        let second = EscapeRoute.next(consoleIsOpen: consoleIsOpen, hasSelectedCard: hasSelectedCard)
        #expect(second == .deselectCard)

        #expect(EscapeRoute.next(consoleIsOpen: false, hasSelectedCard: false) == .ignored)
    }

    @Test("An open console is dismissed whether or not a card is selected")
    func theConsoleWinsFromEitherSelectionState() {
        for hasSelectedCard in [true, false] {
            #expect(
                EscapeRoute.next(consoleIsOpen: true, hasSelectedCard: hasSelectedCard)
                    == .foldConsole
            )
        }
    }

    // MARK: - 3. Handledness

    @Test("Only the route that does nothing reports itself as unhandled")
    func handlednessFollowsWhetherAnythingHappened() {
        #expect(EscapeRoute.foldConsole.isHandled)
        #expect(EscapeRoute.deselectCard.isHandled)
        #expect(!EscapeRoute.ignored.isHandled)

        // Derived, so a case added later cannot be handled *and* do nothing
        // without someone deciding which it is.
        for route in EscapeRoute.allCases {
            #expect(route.isHandled == (route != .ignored))
        }
    }

    /// The route is total: every combination of the two inputs resolves, and
    /// only the empty board resolves to `.ignored`.
    @Test("Every state resolves, and only the empty one hands the key on")
    func theRouteIsTotal() {
        for consoleIsOpen in [true, false] {
            for hasSelectedCard in [true, false] {
                let route = EscapeRoute.next(
                    consoleIsOpen: consoleIsOpen, hasSelectedCard: hasSelectedCard)
                #expect(
                    route.isHandled == (consoleIsOpen || hasSelectedCard),
                    "console=\(consoleIsOpen) selected=\(hasSelectedCard) resolved to \(route)"
                )
            }
        }
    }
}
