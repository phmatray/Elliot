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
        WindowGroup("Elliot") {
            NavigationStack {
                BoardView()
            }
            .environment(model)
            .frame(minWidth: 1_000, minHeight: 600)
            .task { await model.start() }
        }
        // Wide enough that the five columns and the inspector coexist without
        // the board scrolling — seeing every column's consequence at once is
        // the point of the layout.
        .defaultSize(width: 1_640, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) {}

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
        }
    }
}
