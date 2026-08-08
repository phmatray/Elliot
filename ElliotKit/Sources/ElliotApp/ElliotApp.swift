import ElliotAppKit
import SwiftUI
import UserNotifications

@main
struct ElliotApp: App {
    @State private var model = ElliotApp.liveModel()
    /// Apple requires the notification delegate be set before the app finishes
    /// launching, which is earlier than `AppModel.start()` runs — hence an
    /// adaptor rather than a line in `.task`.
    @NSApplicationDelegateAdaptor(NotificationAppDelegate.self) private var appDelegate

    init() {
        // Needed when the binary is run directly rather than from inside a
        // bundle: without it the process starts as an accessory and never
        // shows a window.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    /// The **only** place Elliot opts into writing a preference to disk (#132).
    ///
    /// Everything else — every test, `swift run ElliotApp` under a suite —
    /// gets `AppModel()`, whose writer has nowhere to write. Keeping the choice
    /// here rather than behind a default inside `ElliotAppKit` is what makes
    /// "no test writes a preference it did not ask to" a property of the code
    /// rather than a habit.
    ///
    /// One `PreferencesFile`, read from and written to, so the value restored and
    /// the value saved cannot end up being two different files.
    private static func liveModel() -> AppModel {
        let file = PreferencesFile.atDefaultLocation()
        return AppModel(preferences: file, initialPreferences: file.load())
    }

    var body: some Scene {
        // `Window`, not `WindowGroup`: there is one board, backed by one store
        // that only this process may write. A second copy of it would be a
        // second view of the same rows with no way to tell them apart.
        //
        // The `NavigationStack` is not decoration. `.toolbar` is written
        // against a navigation container, and that container is what reserves
        // the title-bar band and gives the content its top safe-area inset.
        // Removing it (#47) left nothing reserving that strip: the board was
        // laid out from the very top of the window, the traffic lights landed
        // on the column headers, and the status bar was pushed off the bottom
        // by exactly the height lost at the top. See #52.
        Window("Elliot", id: "board") {
            NavigationStack {
                BoardView()
            }
            .environment(model)
            .frame(minWidth: 1_000, minHeight: 600)
            .task {
                // The delegate exists before this runs; it only lacked the model
                // to select a card on.
                appDelegate.handler.model = model
                await model.start()
            }
        }

        // ⌘, for free.
        //
        // ⚠️ `.environment(model)` is load-bearing since #222. The view reads the
        // notification preference off `AppModel` now — they live in
        // `preferences.json`, not `UserDefaults` — and a `Scene` does **not**
        // inherit another scene's environment. Without this line
        // `@Environment(AppModel.self)` compiles, passes every test, and traps
        // at launch with *"No Observable object of type AppModel found"*: the
        // #64 shape, which `swift test` cannot see because `ElliotApp` is an
        // `executableTarget` no test can import.
        Settings {
            NotificationSettingsView().environment(model)
        }
        // Wide enough for the five columns to sit side by side with the panel
        // shut, which is when seeing every column's consequence at once is the
        // point of the layout.
        //
        // With the panel open the board scrolls, **by design and always**: the
        // panel is measured in columns, so at this size the row comes to 2 618pt
        // against a 1 640pt window, and there is no window size the app allows
        // where it fits (`PanelLayout.contentWidth`, pinned by
        // `PanelLayoutTests`). Widening the default would not buy the old
        // claim back — it would only move the number. The board frames the card
        // and its panel together instead, and the columns either side stay one
        // scroll away.
        .defaultSize(width: 1_640, height: 840)
        .commands { commands }

        // Preflight and Repositories were a `NavigationStack` push and a modal
        // sheet — both of which cover the board. That is the wrong shape for
        // this app: runs last minutes, the board is what reports them, and the
        // detail panel has said since it was a sheet that watching a run should
        // not blindfold the board — which is now also why it opens beside the
        // card rather than at the window's edge.
        //
        // Analysis was the sharpest case of all, and it is no longer here. It
        // starts up to eight runs, three at a time, and its whole output is
        // cards in Backlog — so a window for it covered the very column it
        // fills. Since #151 it is the board's leading slot, `BoardSlot.analysis`,
        // beside that column, toggled from the toolbar and from View ▸ Show
        // Analysis. There is exactly one path to it, and it is the board.
        //
        // Each root here keeps a `NavigationStack` for the same reason the board
        // does: `RepositoriesView` and `PreflightView` were written as
        // `NavigationLink` destinations and still carry `.navigationTitle` and
        // `.safeAreaInset`, both of which want that container.
        Window("Repositories", id: "repositories") {
            NavigationStack { RepositoriesView() }.environment(model)
        }
        .defaultSize(width: 900, height: 700)

        // Operations and Up next were windows here until the console landed.
        // They are `ConsoleFace` cases now, unfolded above the status bar in
        // *this* window, and the figures in that status bar are their doors.
        //
        // The reason is the one #151 gave for retiring the Analysis window: a
        // window for a screen that reports on the board covered the board it
        // reported on, and the reader had to place it themselves. It is also
        // what makes them reachable at all — #232 measured that every window but
        // this one answers `board_screenshot` with `window_not_open`, because
        // opening one takes a click and an agent has no click.

        Window("Preflight", id: "preflight") {
            NavigationStack { PreflightView() }.environment(model)
        }
        .defaultSize(width: 820, height: 720)

        // Everything the board's Done horizon is not drawing. Wrapped, like
        // Repositories and Operations: it carries a `.navigationTitle` and a
        // `.searchable`, and both want the container.
        Window("Archive", id: "archive") {
            NavigationStack { ArchiveView() }.environment(model)
        }
        .defaultSize(width: 620, height: 720)

        // A window rather than the fixed 580x580 sheet it was. That sheet had
        // already grown an internal ScrollView because at three or four
        // acceptance criteria — the documented normal path — it pushed its own
        // buttons off the bottom, and a macOS sheet cannot be resized. Writing
        // a story also no longer blocks the board while a run reports on it.
        Window("New story", id: "newStory") {
            NavigationStack { NewCardWindow() }.environment(model)
        }
        .defaultSize(width: 620, height: 640)

    }

    @CommandsBuilder
    private var commands: some Commands {
        CommandGroup(replacing: .newItem) {
            // The shortcut lives here rather than on the toolbar button: a menu
            // item is the discoverable half of a keyboard shortcut, and the
            // toolbar was carrying ⌘N invisibly.
            NewStoryMenuItem(model: model)
                .disabled(model.repos.isEmpty)
        }

        // Advancing a card is the app's central verb. It should be in the
        // menus with a shortcut, not reachable only by dragging — which is
        // slow across four columns and impossible without a pointer.
        CommandMenu("Card") {
            Button("Advance") {
                Task { await model.nudgeSelection(forward: true) }
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(model.selectedCard == nil)

            Button("Move back") {
                Task { await model.nudgeSelection(forward: false) }
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(model.selectedCard == nil)

            Divider()

            // No Escape key equivalent here on purpose. A menu shortcut is
            // matched before the responder chain, so it would take Escape
            // from whatever is focused and deselect behind it instead. The
            // board handles Escape itself, where it can only fire while the
            // board has focus, and `EscapeRoute` states the order.
            //
            // The decision is unchanged since it was written; its example is
            // not. It named "whichever sheet is open", and this package has
            // no sheets — zero `.sheet(`, measured in #261. The live claimant
            // is `ProposalEditor`'s `.onExitCommand`, an inline editor inside
            // this very window, which a menu shortcut would indeed rob.
            Button("Deselect") { model.selectedCardID = nil }
                .disabled(model.selectedCard == nil)
        }

        // Going from "this repository wants attention" to its cards is the
        // Repositories page's other half, and criterion 4 of #143 is the same
        // position the Card menu above states: an act worth a button is an act
        // worth a shortcut, and a shortcut with no menu item is invisible.
        CommandMenu("Repository") {
            OpenBoardMenuItem(model: model)
        }

        // Everything the toolbar offers, reachable without a pointer and
        // discoverable by reading the menus.
        CommandGroup(after: .toolbar) {
            Button("Refresh from GitHub") {
                Task { await model.refreshFromGitHub() }
            }
            .keyboardShortcut("r")
            .disabled(model.repos.isEmpty || model.isImporting)

            // Gated on the selection again, matching the toolbar button: the
            // panel only renders for a selected card, so offering to show it
            // with nothing selected would name an act that does nothing.
            Button(model.showingInspector ? "Hide Details" : "Show Details") {
                model.showingInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(model.selectedCard == nil)

            // How wide the panel is, is the reader's call and nothing else's —
            // the panel is measured in board columns, so widening it is spending
            // columns. There is no toolbar button for it: this is a preference
            // set once, not a control worth a permanent seat.
            // Which width is "the other one" is a rule, so it is the model's and
            // not this menu's (#132). It used to be two literal `3`s and a `2`
            // spelt out here, beside the single definition `Preferences.spanChoices`
            // had just become: a menu that set a span the panel is not designed at
            // would be persisted unclamped and then silently repaired to the
            // default on the next launch — a preference that quietly forgets
            // itself. Reaching `Preferences` from here would also mean importing
            // `ElliotModel`, and this target depends on `ElliotAppKit` and nothing
            // else.
            Button(model.panelWidthToggleTitle) { model.togglePanelWidth() }
                .disabled(model.selectedCard == nil)

            // The analysis panel's pair of the two above. Not gated on a
            // repository being selected: the panel states that refusal itself,
            // and a toggle you cannot switch off is worse than one that opens
            // onto an explanation.
            Button(model.showingAnalysisPanel ? "Hide Analysis" : "Show Analysis") {
                model.showingAnalysisPanel.toggle()
            }
            .keyboardShortcut("a", modifiers: [.command, .option])

            // Title and act both from the model, for the reason the Details pair
            // above already gives: which width is "the other one" is a judgement
            // about the designed pair, and spelling it here meant two literal
            // `3`s and a `2` in a target that cannot import `ElliotModel` — so
            // the menu could set a span the panel is not designed at, which
            // `PreferencesFile.load` would then silently repair to the default.
            // A preference that quietly forgets itself.
            Button(model.analysisWidthToggleTitle) {
                model.toggleAnalysisWidth()
            }
            .disabled(!model.showingAnalysisPanel)

            // How tall the console is, is the reader's call, exactly as the two
            // panel widths are. Title and act both from the model for the reason
            // spelled out on the pair above: which height is "the other one" is
            // a judgement about the designed pair, and this target cannot import
            // `ElliotModel` to consult it.
            Button(model.consoleHeightToggleTitle) { model.toggleConsoleHeight() }
                .disabled(!model.console.isOpen)

            Divider()

            OpenWindowButtons(model: model)
        }
    }
}

/// New Story, as a menu item.
///
/// A `View` for the same reason `OpenWindowButtons` is one: `openWindow` is an
/// environment value and `Commands` is not a view hierarchy that can read one.
/// The shortcut stays here and not on the toolbar button — a shortcut declared
/// in two places is matched reliably in neither.
///
/// ⚠️ The model is **passed in, never read from the environment**. `Commands` is
/// not under the `.environment(model)` that each `Window`'s content carries, so
/// `@Environment(AppModel.self)` here compiles, passes every test, and kills the
/// app at launch with "No Observable object of type AppModel found". It did
/// exactly that in #64, and only launching the app found it. `openWindow` is
/// safe because it is a built-in environment value that `Commands` does provide.
private struct NewStoryMenuItem: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Story…") {
            model.newCardRepoID = model.defaultRepoIDForNewCard
            openWindow(id: "newStory")
        }
        .keyboardShortcut("n")
    }
}

/// Open Board for the Selected Repository, as a menu item.
///
/// ⚠️ The model is **passed in, never read from the environment**, for the
/// reason spelled out on `NewStoryMenuItem` above: `@Environment(AppModel.self)`
/// in a `Commands` tree compiles, passes every test, and kills the app at launch
/// (#64, #84). This item is the second one written to that shape.
private struct OpenBoardMenuItem: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // The judgement is `AppModel`'s, not this item's: unwrapping the action
        // and checking the registration still exists is the same act the row's
        // button performs, and this target cannot reuse the view's private
        // method. Repeating it here would make ⌘↩ a fifth copy of a decision
        // the feature exists to hold in one place.
        Button("Open Board for Selected Repository") {
            guard model.showBoard(model.selectedRowBoardAction) else { return }
            openWindow(id: "board")
        }
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!model.canOpenBoardForSelectedRow)
    }
}

/// The auxiliary screens, as menu items.
///
/// A `View` rather than inline buttons because `openWindow` is an environment
/// value, and `Commands` is not a view hierarchy that can read one.
///
/// ⚠️ **Two kinds of item now sit here, and they are not interchangeable.** The
/// console faces call `showConsoleFace`, which is a *destination*: a menu item
/// named "Operations" that closed Operations because it happened to be open
/// would do the opposite of what it says on every second use. The doors in the
/// status bar are the toggles, because a door carries the figure that makes a
/// toggle read as one. The remaining `openWindow` items are screens whose scenes
/// have not moved yet.
///
/// The model is **passed in, never read from the environment**, for the reason
/// `NewStoryMenuItem` records: `@Environment(AppModel.self)` in a `Commands`
/// tree compiles, passes every test, and kills the app at launch (#64, #84).
private struct OpenWindowButtons: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Operations") { model.showConsoleFace(.operations) }
        Button("Up Next") { model.showConsoleFace(.nextSteps) }
        // No Analysis entry: it is not a window any more (#151). Show/Hide
        // Analysis lives with the other View items, beside Show/Hide Details.
        Button("Repositories") { openWindow(id: "repositories") }
        Button("Preflight") { openWindow(id: "preflight") }
        Button("Archive") { openWindow(id: "archive") }
    }
}


/// Sets the notification delegate before the app finishes launching.
///
/// Apple's requirement, and the reason this exists at all rather than a line in
/// `AppModel.start()`: a delegate set later misses a click that launched the
/// app. The bundle guard is the same one the delivery factory uses —
/// `UNUserNotificationCenter.current()` raises without a bundle identifier, so
/// `swift run ElliotApp` must not reach it.
@MainActor
final class NotificationAppDelegate: NSObject, NSApplicationDelegate {
    /// Built lazily: `NotificationClickHandler` is main-actor isolated, and
    /// `NSApplicationDelegateAdaptor` constructs its delegate off that actor.
    /// `applicationWillFinishLaunching` is already on the main actor, which is
    /// the only place this is touched.
    private var _handler: NotificationClickHandler?
    var handler: NotificationClickHandler {
        if let _handler { return _handler }
        let made = NotificationClickHandler()
        _handler = made
        return made
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = handler
    }
}
