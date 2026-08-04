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
            .frame(minWidth: 900, minHeight: 560)
            .task { await model.start() }
        }
        .defaultSize(width: 1400, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
