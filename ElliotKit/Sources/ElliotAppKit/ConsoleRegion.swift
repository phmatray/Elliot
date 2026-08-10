import ElliotModel
import SwiftUI

/// The console: one screen, unfolded above the status bar, inside the board
/// window.
///
/// It replaces a `Window` scene per screen. What that buys is not tidiness — it
/// is that a screen becomes *reachable*. #232 measured the old shape: every
/// window but the board answers `board_screenshot` with `window_not_open`,
/// because opening one takes a click and an agent has no click. A face has no
/// window to open.
///
/// It also settles a question the four peer windows never answered. The board
/// says what work exists; Operations says what the machine is doing. Those are
/// two readings of one situation, and as separate windows the reader had to
/// place them on screen themselves — usually on top of the thing they were
/// about.
///
/// ⛔ **No `@Environment(\.dismiss)` here**, for the reason `AnalysisPanelView`
/// records: in a region inside the board window it resolves to *the board*, so a
/// Close button would close the application's main window. Folding the console
/// is `model.closeConsole()`.
struct ConsoleRegion: View {
    @Environment(AppModel.self) private var model
    let face: ConsoleFace
    let height: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: height)
        // The ground the two panels already use, and for the same reason: this
        // is a region inside the board window, so it takes the window's own
        // adaptive background rather than a brand colour.
        //
        // ⚠️ It was `Palette.paper` for one build, which is a **brand ink**, not
        // a surface — it resolved near-white behind light text and the whole
        // console was unreadable in dark mode. Every one of 1 736 tests passed
        // on that build. `swift test` cannot see a colour any more than it can
        // see a position.
        .background(Color(nsColor: .windowBackgroundColor))
        // Named as one thing so a screen reader meets "Operations, console"
        // rather than a loose pile of rows above the status bar.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(face.title), console")
    }

    // MARK: - Header

    /// The title, and the one way back.
    ///
    /// The ✕ is here and not only on the door, because a reader who reached this
    /// screen from the menu never pressed a door and would otherwise have to
    /// learn which figure in the status bar corresponds to what they are
    /// reading.
    private var header: some View {
        HStack(spacing: 8) {
            Text(face.title)
                .font(Type.label)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Button {
                model.closeConsole()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.quiet)
            .help("Fold this away. Escape does the same.")
            .accessibilityLabel("Fold the console away")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // Fixed, and for the reason the status bar below it is fixed: a strip
        // whose height follows its contents has shoved this window's board
        // around before.
        .frame(height: Metric.statusBarHeight)
    }

    // MARK: - Content

    /// ⚠️ **Exhaustive over `ConsoleFace`, with no `default`.** That is the point
    /// of the switch: a face added to the type has to be given something to draw
    /// before this compiles, rather than silently rendering nothing above the
    /// status bar. The two screens whose scenes are gone are reached today; the
    /// rest are written and unreachable until their own door lands, so each
    /// remaining migration is a scene deletion and a door rather than a new
    /// rendering.
    private var content: some View {
        // ⛔ **The `NavigationStack` is load-bearing twice over, and the second
        // reason was found by looking rather than by testing.**
        //
        // It is what each of these views expects: every `Window` scene wrapped
        // its root in one, because they were written as `NavigationLink`
        // destinations and still carry `.navigationTitle` and `.safeAreaInset`,
        // both of which want that container.
        //
        // ⚠️ **It does not, however, contain `.navigationTitle`** — measured, in
        // both directions. With no stack here the window's title bar read
        // *"Operations"* instead of *"Elliot"*; adding the stack did not change
        // that, and neither did re-asserting `.navigationTitle("Elliot")` on
        // this very view, which is an ancestor of the face. A title propagates
        // to the window regardless.
        //
        // So the fix is at the source: a face **must not set a navigation
        // title**, because in a window the `Window("…", id:)` label already
        // supplies one — the two views migrated here were setting it twice —
        // and in the console the title is the header's job. `OperationsView`
        // had its removed, and so had the Up next face before #304 folded it
        // into `OperationsView` as a band.
        //
        // ⛔ **The four faces below still carry one**, and each will rename the
        // board window the moment it becomes reachable. They are unreachable
        // today, which `ConsoleReachabilityTests` guarantees; whoever lands
        // their door removes their `.navigationTitle` in the same change.
        NavigationStack { faceBody }
    }

    @ViewBuilder
    private var faceBody: some View {
        switch face {
        case .operations: OperationsView()
        case .preflight: PreflightView()
        case .repositories: RepositoriesView()
        case .archive: ArchiveView()
        case .newStory: NewStoryView()
        case .dismissed: DismissedView()
        }
    }
}
