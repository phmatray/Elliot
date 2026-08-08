import Foundation

/// What one press of Escape dismisses on the board.
///
/// Today this is a two-line `guard` inside `BoardView.onKeyPress(.escape)`:
/// deselect if something is selected, otherwise hand the key on. Once the
/// console unfolds over the board there is a second dismissable thing, and the
/// order between them stops being obvious — which is the moment a rule earns a
/// type rather than a longer `guard`.
///
/// Pure, and in the model, for this file's usual reason: the board is not the
/// only thing that will want to know what Escape means. The menus have already
/// had to reason about it once (`ElliotApp.commands` deliberately gives Deselect
/// *no* key equivalent, because a menu shortcut is matched ahead of the
/// responder chain and would take Escape from whichever sheet is open).
public enum EscapeRoute: Equatable, Sendable, CaseIterable {

    /// Fold the console away, leaving the selection alone.
    case foldConsole

    /// Clear the selection, which takes the detail panel with it.
    ///
    /// One step, not two. The panel renders *for* a selected card, so there is
    /// no reachable state where dismissing the panel and dismissing the
    /// selection are different acts — and a route that pretended otherwise would
    /// make a reader press Escape twice to get back to a bare board.
    case deselectCard

    /// Hand the key on untouched.
    ///
    /// ⚠️ **Not a no-op, and the reason it is a case rather than `nil`.** The
    /// board returns `.ignored` from `onKeyPress` so the press falls through to
    /// whatever else wants it — a sheet, a text field, the window. A route that
    /// reported "handled, did nothing" would swallow Escape from an open sheet
    /// and leave the reader with no way out of it.
    case ignored

    /// What the next press of Escape does.
    ///
    /// Outermost-last: the console goes before the selection because it arrived
    /// later and covers more, and because a reader who pressed a door is looking
    /// at the console rather than at the card they picked some time ago.
    ///
    /// ⛔ **The analysis panel is deliberately absent from this route, and that
    /// is a decision rather than an omission.** Hiding the analysis panel is not
    /// closing the analysis: `closeAnalysis()` drops the `AnalysisSession`, and
    /// `ObservationHandle.deinit` cancels the live proposal observation with it,
    /// so a stray Escape while eight lenses were reading would stop proposals
    /// landing. Only *Finish* ends a session. Adding a `.hideAnalysis` case here
    /// would also be wrong in the other direction — a panel the reader opened
    /// from the toolbar, holding text they typed, is not transient in the way a
    /// selection is.
    public static func next(consoleIsOpen: Bool, hasSelectedCard: Bool) -> EscapeRoute {
        if consoleIsOpen { return .foldConsole }
        if hasSelectedCard { return .deselectCard }
        return .ignored
    }

    /// Whether the board should report the press as handled.
    ///
    /// Derived rather than stored, so "did we act" and "what did we do" cannot
    /// disagree — the shape `ConsoleState` uses one optional for instead of a
    /// `Bool` beside a face.
    public var isHandled: Bool { self != .ignored }
}
