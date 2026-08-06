import SwiftUI

@main
struct ElliotApp: App {
    @State private var model = AppModel()

    init() {
        // Needed when the binary is run directly rather than from inside a
        // bundle: without it the process starts as an accessory and never
        // shows a window.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        // `Window`, not `WindowGroup`: there is one board, backed by one store
        // that only this process may write. A second copy of it would be a
        // second view of the same rows with no way to tell them apart.
        Window("Elliot", id: "board") {
            BoardView()
                .environment(model)
                .frame(minWidth: 1_000, minHeight: 600)
                .task { await model.start() }
        }
        // Wide enough that the five columns and the inspector coexist without
        // the board scrolling — seeing every column's consequence at once is
        // the point of the layout.
        .defaultSize(width: 1_640, height: 840)
        .commands { commands }

        // Preflight, Repositories and Analysis were a `NavigationStack` push
        // and a modal sheet — both of which cover the board. That is the wrong
        // shape for this app: runs last minutes, the board is what reports
        // them, and `InspectorView`'s own doc comment already says watching a
        // run should not blindfold the board. Analysis is the sharpest case —
        // it starts up to six concurrent runs from inside a modal.
        Window("Repositories", id: "repositories") {
            RepositoriesView().environment(model)
        }
        .defaultSize(width: 900, height: 700)

        Window("Preflight", id: "preflight") {
            PreflightView().environment(model)
        }
        .defaultSize(width: 820, height: 720)

        Window("Analysis", id: "analysis") {
            AnalysisWindow().environment(model)
        }
        .defaultSize(width: 900, height: 760)
    }

    @CommandsBuilder
    private var commands: some Commands {
        CommandGroup(replacing: .newItem) {
            // The shortcut lives here rather than on the toolbar button: a menu
            // item is the discoverable half of a keyboard shortcut, and the
            // toolbar was carrying ⌘N invisibly.
            Button("New Story…") { model.showingNewCard = true }
                .keyboardShortcut("n")
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
            // from whichever sheet is open and deselect behind it instead
            // of closing it. The board handles Escape itself, where it can
            // only fire while the board has focus.
            Button("Deselect") { model.selectedCardID = nil }
                .disabled(model.selectedCard == nil)
        }

        // Everything the toolbar offers, reachable without a pointer and
        // discoverable by reading the menus.
        CommandGroup(after: .toolbar) {
            Button("Refresh from GitHub") {
                Task { await model.refreshFromGitHub() }
            }
            .keyboardShortcut("r")
            .disabled(model.repos.isEmpty || model.isImporting)

            Button(model.showingInspector ? "Hide Details" : "Show Details") {
                model.showingInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(model.selectedCard == nil)

            Divider()

            OpenWindowButtons()
        }
    }
}

/// The three auxiliary windows, as menu items.
///
/// A `View` rather than three inline buttons because `openWindow` is an
/// environment value, and `Commands` is not a view hierarchy that can read one.
private struct OpenWindowButtons: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Analysis…") { openWindow(id: "analysis") }
        Button("Repositories") { openWindow(id: "repositories") }
        Button("Preflight") { openWindow(id: "preflight") }
    }
}
