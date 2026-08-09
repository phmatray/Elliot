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
    /// the responder chain. A route that reported "handled, did nothing" would
    /// claim Escape for something that did not use it.
    ///
    /// **This app has no sheets at all** — zero `.sheet(` in the package,
    /// measured; the things that read like one are a `Window` scene
    /// (`NewCardWindow`) or inline panel regions (`MergeConfirmation`,
    /// `ProposalEditor`). The concrete claimant down the chain is
    /// `ProposalEditor`'s own `.onExitCommand`, which states the stake exactly:
    /// *"Without it the key would fall through to the window, which is the wrong
    /// thing to close while a row is open."*
    ///
    /// ⚠️ **This paragraph also said the one `confirmationDialog` was "applied by
    /// Preflight and Repositories and never by the board", and that stopped
    /// being true the moment those two became console faces (#265).** It is now
    /// presented *inside* the board window, which is why `hasOpenDialog` exists
    /// below rather than being left to focus handling.
    ///
    /// This paragraph blamed a sheet until #261, one commit after it was
    /// written. The conclusion did not change and the reason did — which is the
    /// #186 shape, where four comments went on reasoning from a premise that had
    /// been retired. A wrong reason is worse than none: the next person weighs a
    /// decision against it.
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
    ///
    /// ⛔ **An armed merge is absent for a stronger reason: Escape cannot reach
    /// one today, and giving it one here would be new behaviour wearing the
    /// clothes of a description.** `pendingFollowUps` is dismissed only by the
    /// Cancel button in `MergeConfirmation`, whose Merge is *deliberately*
    /// denied `.keyboardShortcut(.defaultAction)` (#247) because the one act
    /// that cannot be taken back must be reached by pressing it. Whether Escape
    /// should cancel an armed merge is a question nobody has answered; this
    /// route does not answer it by accident.
    ///
    /// ⚠️ **What `.deselectCard` costs is preserved here, not decided.** Clearing
    /// the selection tears down `DetailPanelView` and its `@State` `CardEditor`
    /// with it, so an unsaved edit is discarded with no confirmation — today's
    /// behaviour, unchanged by this rule. If a later route puts "cancel the
    /// edit" ahead of "clear the selection", it is *changing* that rather than
    /// keeping it, and should say so.
    ///
    /// ⛔ **`hasOpenDialog` wins outright, and it is a parameter rather than a
    /// thing left to focus handling.** Until #265 the only `confirmationDialog`
    /// in the package (`ForgetConfirmation`, which asks before a repository is
    /// forgotten) was presented by the Preflight and Repositories *windows*, so
    /// it could not coexist with this board. Those are console faces now and it
    /// is presented inside this window. AppKit very likely gives the dialog the
    /// key press first — but "very likely" is not a rule, and the failure it
    /// would hide is silent and bad: Escape folding the console out from under
    /// an open dialog, leaving a question attached to a screen that is no longer
    /// there. Stated here, it is decided rather than inherited.
    public static func next(
        consoleIsOpen: Bool, hasSelectedCard: Bool, hasOpenDialog: Bool = false
    ) -> EscapeRoute {
        if hasOpenDialog { return .ignored }
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
