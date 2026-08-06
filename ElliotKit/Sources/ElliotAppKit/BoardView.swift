import ElliotEngine
import ElliotModel
import SwiftUI
import UniformTypeIdentifiers

public struct BoardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @FocusState private var boardFocused: Bool

    /// The board's horizontal scroll, held rather than driven through a
    /// `ScrollViewReader`.
    ///
    /// `ScrollViewProxy.scrollTo(_:anchor:)` aligns a view to a `UnitPoint` and
    /// takes no offset, so it cannot express the lead that keeps the previous
    /// column showing — and with the panel inline, `anchor: .center` on the
    /// origin column pushes the panel half off the right edge, or the whole
    /// panel off-screen in the flipped case. `ScrollPosition` takes the x.
    @State private var boardScroll = ScrollPosition(edge: .leading)

    public init() {}

    public var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            // Three states, not two. The board used to assert "No repository
            // yet" for the whole of startup — through the login-shell capture,
            // three tool lookups and a preflight sweep — to a user whose
            // repositories were in the database the entire time.
            if !model.hasLoadedRepos {
                startingState
            } else if model.repos.isEmpty {
                emptyState
            } else {
                board
            }
            Divider()
            StatusBar()
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: model.selectedCardID)
        .toolbar { toolbarContent }
        .navigationTitle("Elliot")
        .task(id: model.selectedRepoID) {
            await model.importIfNeeded(repoID: model.selectedRepoID)
        }
        // The board keeps focus so a card can be moved without the mouse.
        .focusable()
        .focusEffectDisabled()
        .focused($boardFocused)
        .defaultFocus($boardFocused, true)
        .onKeyPress(.escape) {
            guard model.selectedCardID != nil else { return .ignored }
            model.selectedCardID = nil
            return .handled
        }
        // Picking a card was pointer-only, which made every affordance built
        // for the keyboard — ⌘→, ⌘←, Escape, the whole Card menu — depend on a
        // pointer first. The arrows only move the selection; ⌘-arrow still owns
        // moving a card, and no rule leaves ElliotModel.
        .onKeyPress(.downArrow) { stepCard(by: 1) }
        .onKeyPress(.upArrow) { stepCard(by: -1) }
        .onKeyPress(.leftArrow) { stepColumn(by: -1) }
        .onKeyPress(.rightArrow) { stepColumn(by: 1) }
        // A refusal is the one status change a screen-reader user has no other
        // way to learn: the note is drawn on a card they may not be on. Only
        // refusals — announcing `status` wholesale would turn VoiceOver into a
        // ticker of import progress.
        .onChange(of: model.refusal) { _, refusal in
            guard let refusal else { return }
            AccessibilityNotification.Announcement(refusal.message).post()
        }
    }

    // MARK: - Keyboard selection

    /// Move the selection up or down within its column.
    private func stepCard(by delta: Int) -> KeyPress.Result {
        let column = model.selectedCard?.column ?? .backlog
        let cards = model.cards(in: column)
        guard !cards.isEmpty else { return .ignored }
        guard let current = model.selectedCard,
              let index = cards.firstIndex(where: { $0.id == current.id })
        else {
            model.selectedCardID = cards.first?.id
            return .handled
        }
        model.selectedCardID = cards[min(max(index + delta, 0), cards.count - 1)].id
        return .handled
    }

    /// Move the selection sideways, skipping columns that hold nothing. If
    /// every column that way is empty the selection stays put — jumping
    /// somewhere arbitrary is worse than not moving.
    private func stepColumn(by delta: Int) -> KeyPress.Result {
        let order = ElliotModel.Column.allCases
        let from = model.selectedCard?.column ?? (delta > 0 ? .backlog : .done)
        guard let index = order.firstIndex(of: from) else { return .ignored }

        var candidate = model.selectedCard == nil ? index : index + delta
        while order.indices.contains(candidate) {
            if let first = model.cards(in: order[candidate]).first {
                model.selectedCardID = first.id
                return .handled
            }
            candidate += delta
        }
        return .ignored
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            @Bindable var model = model
            Picker("Repository", selection: $model.selectedRepoID) {
                Text("All repositories").tag(UUID?.none)
                ForEach(model.repos) { repo in
                    Text(repo.displayName).tag(UUID?.some(repo.id))
                }
            }
            .labelsHidden()
            .frame(minWidth: 160)
        }

        ToolbarItem {
            Button {
                model.newCardRepoID = model.defaultRepoIDForNewCard
                openWindow(id: "newStory")
            } label: {
                Label("New story", systemImage: "plus")
            }
            .labelStyle(.titleAndIcon)
            .disabled(model.repos.isEmpty)
            // No `.keyboardShortcut` here: the File menu owns ⌘N, and a
            // shortcut declared in two places is matched reliably in neither.
            .help("Write a new backlog story")
        }

        ToolbarItem {
            Menu {
                Button("Forget dismissed items") {
                    Task { await model.clearDismissals() }
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            } primaryAction: {
                Task { await model.refreshFromGitHub() }
            }
            .labelStyle(.titleAndIcon)
            .menuStyle(.button)
            .fixedSize()
            .disabled(model.repos.isEmpty || model.isImporting)
            .help(model.selectedRepoID == nil
                ? "Bring every repository's GitHub issues and pull requests onto the board."
                : "Bring this repository's GitHub issues and pull requests onto the board.")
        }

        ToolbarItem {
            Button {
                openWindow(id: "analysis")
            } label: {
                Label("Analyse", systemImage: "sparkle.magnifyingglass")
            }
            .labelStyle(.titleAndIcon)
            .disabled(model.selectedRepoID == nil || isSelectedRepoBlocked)
            .help(analyseHelp)
        }

        ToolbarItem {
            // Still a Button and not a Toggle. As a Toggle it read
            // `showingInspector`, so the toolbar re-vended its items in the
            // middle of the split view's own collapse animation — the crash in
            // #50.
            //
            // It now reads that state anyway, to tint itself while the panel is
            // open, which is what #50 is a warning about. What made that crash
            // was an `NSSplitViewItem` collapsing *while* the toolbar rebuilt;
            // the panel is a plain sibling in an `HStack` now and there is no
            // split view left to collapse. The tint is worth it because the
            // panel no longer sits at a fixed edge: it opens between columns
            // and the board scrolls, so "is a panel open" stopped being
            // answerable at a glance. Toggled repeatedly on screen before this
            // landed — if it ever crashes on collapse again, this is the line.
            Button {
                model.showingInspector.toggle()
            } label: {
                Label("Details", systemImage: "sidebar.right")
            }
            .labelStyle(.titleAndIcon)
            .tint(isPanelShowing ? Palette.armed : nil)
            .foregroundStyle(isPanelShowing ? Palette.armed : Color.primary)
            .disabled(model.selectedCard == nil)
            .help(isPanelShowing
                ? "Hide the selected card's details"
                : "Show the selected card's details")
        }

        ToolbarItem {
            Button {
                openWindow(id: "repositories")
            } label: {
                Label("Repositories", systemImage: "square.stack.3d.up")
            }
            .labelStyle(.titleAndIcon)
            .help("Every repository of your accounts, and what is wrong with it")
        }

        ToolbarItem {
            Button {
                openWindow(id: "preflight")
            } label: {
                Label("Preflight", systemImage: "checkmark.seal")
            }
            .labelStyle(.titleAndIcon)
            .help("Check the tools and repositories Elliot depends on")
        }
    }

    /// Whether a panel is actually drawn, which is both flags and not either
    /// one: `showingInspector` can be true with nothing selected, and a
    /// selection means nothing while the panel is hidden.
    private var isPanelShowing: Bool {
        model.showingInspector && model.selectedCard != nil
    }

    /// Says which gate is closed, rather than repeating the one that is open.
    ///
    /// The button is disabled for three different reasons and the tooltip named
    /// only the first, so a blocked or switched-off repository produced a
    /// disabled control whose explanation was about something else.
    private var analyseHelp: String {
        guard let id = model.selectedRepoID,
              let repo = model.repos.first(where: { $0.id == id })
        else { return "Pick a single repository to analyse." }
        if !repo.isEnabled { return Consequence.reason(.repoDisabled) }
        if model.isBlocked(repo) {
            return "A Preflight check is failing for this repository — fix it there first."
        }
        return "Read this repository through several lenses and propose stories."
    }

    /// The five columns and, when a card is selected, its detail panel between
    /// them — one ordered row, `PanelLayout.boardOrder` deciding the order.
    ///
    /// The panel is a **sibling in this row**. Not a split of the window: as
    /// `.inspector()` it bought drag-to-resize and cost the window its layout,
    /// because applied to the stack that also holds the Divider and StatusBar
    /// the split covered the strip the title bar occupies — the board rode up
    /// under the traffic lights and the status bar fell off the bottom (#52),
    /// after it had already crashed on a collapse (#50). And not an overlay
    /// either, which would look identical and be wrong invisibly: an overlay is
    /// not a sibling, so VoiceOver would reach the panel somewhere other than
    /// after its origin column with no visible symptom.
    ///
    /// Everything below the row — the Divider and the StatusBar — is outside
    /// it, which is what keeps the status bar full-width at the bottom and the
    /// board's height the same whether the panel is open or shut.
    private var board: some View {
        // The board has exactly five columns and always will — the rule engine
        // is a fixed transition matrix. So they share the width rather than
        // sitting at a fixed size that leaves Done half off-screen.
        // The formula itself lives in `PanelLayout`, where a test can pin it:
        // the detail panel is measured in columns, so its width and this one
        // have to be the same number rather than two copies of it.
        GeometryReader { geometry in
            let boardWidth = geometry.size.width
            let width = PanelLayout.columnWidth(boardWidth: boardWidth)

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Metric.gutter) {
                    ForEach(PanelLayout.boardOrder(selected: panelOrigin), id: \.self) { slot in
                        switch slot {
                        case .column(let column):
                            ColumnView(column: column, width: width)
                        case .panel:
                            panel(width: width)
                        }
                    }
                }
                .padding(Metric.gutter)
                .frame(minWidth: boardWidth, alignment: .leading)
                // The caret and its tether, drawn over the whole row rather
                // than inside the panel. They sit *outside* the panel's bounds
                // by design, and in the flipped case they hang over Done — up
                // here nothing clips them and nothing paints over them. The
                // card, the origin column's viewport and the panel all arrive
                // as anchors, so one `GeometryProxy` resolves the three in one
                // space and the caret is drawn from the layout pass that is
                // happening rather than the one before it.
                .overlayPreferenceValue(CaretAnchorKey.self) { anchors in
                    CaretRail(anchors: anchors, flipped: isPanelFlipped)
                }
            }
            .scrollPosition($boardScroll)
            // Derived from the same width function the row is built from, never
            // a second copy of the arithmetic. The old predicate asked only
            // whether five columns fit, so with the panel open it reported
            // "everything fits" over content 1.6–1.7× the viewport — leaving
            // the panel or Done silently unreachable with no scrollbar, green
            // on both `swift build` and `swift test`.
            .scrollDisabled(
                PanelLayout.contentWidth(boardWidth: boardWidth, spans: openSpans) <= boardWidth
            )
            // In a window too narrow for what the row holds the board scrolls,
            // and the card you just selected could be the one off-screen.
            .onChange(of: model.selectedCardID) { frame(boardWidth: boardWidth) }
            // A second handler, because `nudgeSelection` never touches
            // `selectedCardID`: ⌘→ advanced a card into a column the board did
            // not follow it to. Both route through the one `frame(boardWidth:)`
            // — updating only the click path is how the keyboard fell behind
            // the card in the first place.
            .onChange(of: model.selectedCard?.column) { frame(boardWidth: boardWidth) }
        }
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
        // No deselect gesture here any more; `ColumnView` carries it.
        //
        // It lived here and fired by bubbling, which stopped working the moment
        // the panel widened the row past the viewport: an enabled `ScrollView`
        // swallows the tap, so nothing deselected at all. Moving it to the row's
        // background fixed that and broke the opposite direction — that
        // background also lies under the panel, so a click on the panel being
        // read closed it, and the panel's own empty `onTapGesture` did not
        // absorb it.
        //
        // An ancestor's tap fires for taps on its descendants, so any deselect
        // above the panel is a deselect *through* the panel. The reach has to be
        // the columns themselves. What that gives up is the 10pt padding ring,
        // which no longer deselects; Escape still does, and the columns cover
        // the gesture anyone actually makes.
    }

    /// The column the panel opens beside, or `nil` when there is no panel — the
    /// one place "is the panel showing" is decided, so the order, the width of
    /// the row and the framing cannot disagree about it.
    private var panelOrigin: ElliotModel.Column? {
        guard model.showingInspector, let card = model.selectedCard else { return nil }
        return card.column
    }

    /// The reader's span preference while the panel is open, `nil` while it is
    /// shut — which is the shape `PanelLayout.contentWidth` takes for "no
    /// panel", so the closed board measures exactly what it measures today.
    private var openSpans: Int? {
        panelOrigin == nil ? nil : model.panelSpans
    }

    /// Which edge of the panel the caret hangs off, decided by the same function
    /// that put the panel on that side of its column. Reading it off
    /// `panelOrigin` rather than off the card is deliberate: the panel and its
    /// caret cannot then disagree about which column they belong to.
    private var isPanelFlipped: Bool {
        panelOrigin.map(PanelLayout.opensLeft(of:)) ?? false
    }

    /// The detail panel, as one slot of the row.
    private func panel(width: CGFloat) -> some View {
        DetailPanelView(columnWidth: width)
            // Where the caret's flat side goes. The panel's anchor is also the
            // whole "is there a caret" condition — it exists exactly while the
            // panel is built, so there is no second copy of that question.
            .anchorPreference(key: CaretAnchorKey.self, value: .bounds) {
                CaretAnchors(panel: $0)
            }
            // Load-bearing. Later siblings paint over earlier ones, and in the
            // flipped case the panel is placed *before* Done — whose
            // background, clip and border would paint over the caret notched
            // into the panel's edge and the tether reaching across the gutter.
            // That would be invisible in exactly one column and nowhere else: a
            // bug that survives every test and most manual passes.
            .zIndex(1)
            // The board clears the selection on a click that reaches its
            // background, and this panel now sits inside that container. Without
            // absorbing its own strays, clicking the panel's padding, a section
            // label or its header would close the panel being read.
            .contentShape(Rectangle())
            .onTapGesture {}
            // `BoardSlot.panel` is one constant identity, so changing origin
            // column re-orders the panel instead of destroying and rebuilding
            // it — that is what stops a second panel and a second caret
            // appearing mid-transition. This is the other half of that: a
            // re-order is a frame change, and a frame change under the
            // stack-wide `.animation(…, value: selectedCardID)` interpolates,
            // so Backlog → Done would send the panel gliding across four
            // columns. The panel's own placement does not animate; the columns
            // sliding aside still does.
            //
            // ⚠️ Deliberately a bare `nil`, and not the `reduceMotion ? nil : …`
            // every other animation on this board is written as. This one is
            // unconditional: the panel must not glide for anyone, reduce motion
            // on or off. So it is *stricter* than reduce motion asks for rather
            // than an ungated animation — there is no animation here to gate.
            // Turning it into `reduceMotion ? nil : .something` would reinstate
            // the glide for everyone who has not switched reduce motion on.
            .animation(nil, value: model.selectedCardID)
    }

    /// Scroll the board so the selected card's column and its panel are framed
    /// together, with a lead of the previous column still showing.
    ///
    /// One helper, both handlers. It works out where the pair *will* be rather
    /// than measuring where it is: the row is an `HStack` of known widths, so
    /// `PanelLayout.minX` answers before the layout that inserts the panel has
    /// run — which is what lets the first click frame the pair instead of
    /// framing the board as it was a moment ago.
    private func frame(boardWidth: CGFloat) {
        guard let column = model.selectedCard?.column else { return }
        let origin = panelOrigin
        let slots = PanelLayout.boardOrder(selected: origin)
        let columnWidth = PanelLayout.columnWidth(boardWidth: boardWidth)
        let panelWidth = PanelLayout.panelWidth(
            columnWidth: columnWidth, spans: model.panelSpans
        )

        guard let originMinX = PanelLayout.minX(
            of: .column(column), in: slots, columnWidth: columnWidth, panelWidth: panelWidth
        ) else { return }
        // Only read when the pair is flipped, and it is flipped only when there
        // is a panel — so the fallback is unreachable rather than a guess.
        let panelMinX = PanelLayout.minX(
            of: .panel, in: slots, columnWidth: columnWidth, panelWidth: panelWidth
        )
        let offset = PanelLayout.frameOffsetX(
            originMinX: originMinX,
            panelMinX: panelMinX ?? originMinX,
            flipped: origin != nil && PanelLayout.opensLeft(of: column)
        )

        // Deferred by one turn of the main actor, and this is the whole reason
        // the first attempt did nothing on screen. `onChange` runs *inside* the
        // update that changed the selection, so the row it scrolls is still the
        // one without a panel: five columns, content no wider than the
        // viewport, `scrollDisabled` still true. The offset was computed for
        // the row that was about to exist and applied to the row that still
        // did, where it clamps to zero. Both `swift build` and `swift test`
        // were green through all of it — the board simply never moved, and only
        // the last column showed it, because that is the one case where the
        // pair does not already fit.
        Task { @MainActor in
            withAnimation(reduceMotion ? nil : .default) {
                boardScroll.scrollTo(x: offset)
            }
        }
    }

    /// Startup, said in the same words `RepositoriesView` already uses for it,
    /// so the two screens stop disagreeing about one launch.
    private var startingState: some View {
        ContentUnavailableView(
            "Still starting", systemImage: "hourglass", description: Text(model.status)
        )
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No repository yet", systemImage: "folder.badge.plus")
        } description: {
            Text("Add the main checkout of a git repository. Elliot files issues, opens pull requests and merges them there.")
        } actions: {
            Button("Add a repository…") { chooseRepository() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxHeight: .infinity)
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        panel.message = "Choose the main checkout — not a linked worktree."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.addRepo(path: url.path) }
    }

    /// Analysis is refused for the same repositories cards are: a blocked repo
    /// would fail at the first run anyway, and saying so here is cheaper.
    private var isSelectedRepoBlocked: Bool {
        guard let id = model.selectedRepoID, let repo = model.repos.first(where: { $0.id == id })
        else { return true }
        return !repo.isEnabled || model.isBlocked(repo)
    }
}

// MARK: - Status bar

/// The only strip that is always on screen, and until #68 it carried the least
/// information available: "N running" and a status sentence. Neither the queue
/// depth, nor the capacity in use, nor the day's spend appeared — although all
/// three were either already in memory or one aggregate query away.
///
/// It says the three numbers of a control room now. Each opens the screen that
/// can act on it, so the strip is a way in rather than a readout.
struct StatusBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 8) {
            if !model.isReady || model.isImporting {
                ProgressView().controlSize(.small)
            }
            // `refreshFromGitHub` joins one sentence per repository, which
            // used to wrap and grow `.bar`, shoving the whole board upwards.
            Text(model.status)
                .font(Type.prose)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(model.status)

            Spacer(minLength: 8)

            figure(
                text: "\(model.occupancy.writers)/\(model.limits.maxConcurrent) workers",
                tint: model.occupancy.writers > 0 ? Palette.armed : Palette.quiet,
                help: "How many runs are going, against the limit. Click to change it.",
                spoken: "\(model.occupancy.writers) of \(model.limits.maxConcurrent) workers busy",
                window: "operations"
            )

            // Only when there is one. A permanent "0 queued" is furniture, and
            // this strip has been pushed around by its own contents before.
            if !model.queue.isEmpty {
                figure(
                    text: "\(model.queue.count) queued",
                    tint: model.isQueuePaused ? Palette.refused : Palette.attention,
                    help: model.queue.first?.refusal.sentence ?? "Runs waiting to start.",
                    spoken: model.isQueuePaused
                        ? "\(model.queue.count) queued, paused"
                        : "\(model.queue.count) runs queued",
                    window: "operations"
                )
            }

            figure(
                text: MoneyFormat.usd(model.spentToday.totalUSD),
                tint: model.isOverDailyCeiling ? Palette.refused : Palette.quiet,
                help: "Spent today — \(model.spentToday.sentence()). Click to set a ceiling.",
                spoken: "spent today, \(model.spentToday.sentence())",
                window: "operations"
            )

            // Elliot wrote this hint, so it is not set in the fact face.
            Text(
                model.selectedCard == nil
                    ? "↑↓←→ pick a card"
                    : "⌘→ advance · ⌘← back · esc deselect"
            )
            .font(Type.prose)
            .foregroundStyle(Palette.quiet)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // Fixed, and `lineLimit(1)` above: this bar has grown and shoved the
        // whole board upwards before, and the numbers in it change constantly.
        .frame(height: Metric.statusBarHeight)
        .background(.bar)
    }

    /// One figure, and a way to act on it.
    ///
    /// `spoken` rather than reading the label aloud: "2/4 workers" is a
    /// screen-reader's nightmare, and a number with no sentence around it says
    /// nothing to anyone who cannot see where it sits.
    private func figure(
        text: String, tint: Color, help: String, spoken: String, window: String
    ) -> some View {
        Button { openWindow(id: window) } label: {
            Fact(text: text, tint: tint, small: true)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(spoken)
        .accessibilityHint("Opens the screen that can change it")
    }
}

// MARK: - Column

struct ColumnView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let column: ElliotModel.Column
    let width: CGFloat
    @State private var isTargeted = false
    /// Per column and per repository, so collapsing a repository in Backlog does
    /// not hide it in To Do — the two are different questions.
    @State private var collapsed: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            rail
            header
            list
        }
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(background)
        // Clearing the selection belongs to the columns, not to the row.
        //
        // It used to sit on the board container and work by bubbling out of a
        // column's empty space — but only because the old predicate disabled
        // scrolling whenever five columns fit, and a disabled `ScrollView`
        // passes a tap through. The panel makes the row wider than the viewport
        // by design, so scrolling is now always on while it is open, an enabled
        // `ScrollView` swallows the tap, and the board became impossible to
        // deselect by clicking — in every column, with `swift build` clean and
        // all 726 tests green. Caught by looking, and confirmed a regression by
        // driving `main` through the same gesture.
        //
        // Putting it on the row's background instead only moved the bug: that
        // background also lies under the panel, so clicking the panel being read
        // closed it. Here the reach is exactly right — a column's own empty
        // space and nothing else. Cards sit in front and keep their own tap.
        .contentShape(Rectangle())
        .onTapGesture { model.selectedCardID = nil }
        .clipShape(RoundedRectangle(cornerRadius: Metric.columnRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.columnRadius)
                .strokeBorder(borderTint, lineWidth: isTargeted ? 2 : 1)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            // Answered now, not a round trip later. `move` is async, so this
            // closure used to return `true` — "accepted" — for drops it was
            // about to refuse: the card animated in, then jumped back with a
            // note on it. Returning `false` makes the drag snap back, which is
            // what a refusal looks like on this platform.
            guard !model.refuse(cardID: id, to: column) else { return false }
            Task { await model.move(cardID: id, to: column) }
            return true
        } isTargeted: { targeted in
            // The refusal is stated in the header the whole time a card is
            // selected, so a refused column simply does not light up.
            isTargeted = targeted && !isRefused
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: isTargeted)
    }

    /// The column's standing cost, always visible. Two points of colour, and
    /// only where arriving actually does something.
    private var rail: some View {
        Rectangle()
            .fill(consequence?.tint ?? column.railTint)
            .frame(height: Metric.railHeight)
            .opacity(isRefused ? 0.25 : 1)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                ConsoleLabel(text: column.displayName, tint: .primary)
                Fact(text: "\(cards.count)", tint: Palette.quiet, small: true)
                Spacer()
                if column.isConsequential {
                    Image(systemName: column == .done ? "flame.fill" : "bolt.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(column.railTint)
                        .accessibilityHidden(true)
                }
            }

            // The heart of it: what a drop here does, decided by the same pure
            // function that will run it. No card selected, no card in hand —
            // the column falls back to describing itself.
            Text(consequence?.summary ?? column.standingRule)
                .font(Type.prose)
                .foregroundStyle(captionTint)
                .lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        // One of the five captions #79 requires to survive the panel. Built by
        // a pure function so that survival is a claim `swift test` can hold —
        // the string itself used to be written here, where nothing could.
        .accessibilityLabel(
            BoardAccessibility.columnCaption(
                name: column.displayName,
                count: cards.count,
                rule: consequence?.summary ?? column.standingRule
            )
        )
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    // Grouped only when the picker says "All repositories".
                    // With one repository chosen every card belongs to it, and a
                    // header repeating its name on every column is furniture.
                    if let groups {
                        ForEach(groups) { group in
                            groupHeader(group)
                            if !collapsed.contains(group.repoID) {
                                ForEach(group.cards) { card in
                                    draggable(card)
                                }
                            }
                        }
                    } else {
                        ForEach(cards) { card in
                            draggable(card)
                        }
                    }

                    if cards.isEmpty {
                        // Driven by the gated `.animation(…, value: cards.map(\.id))`
                        // a few lines down — the last card leaving is what
                        // makes this appear, and that *is* a change to that
                        // value. With reduce motion on the gate hands SwiftUI
                        // `nil` and the hint is simply there.
                        dropHint.transition(.opacity)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .top)
                // On the list itself, not the board: this is about membership
                // of *this* column changing.
                .animation(reduceMotion ? nil : .snappy(duration: 0.24), value: cards.map(\.id))
            }
            .scrollBounceBehavior(.basedOnSize)
            // A dropped card landed at the bottom of a column nothing scrolled,
            // so a full column swallowed it. The guard keeps the other four
            // columns still. No colour flash is needed — the card that just
            // landed is already selected and already wears the armed border.
            .onChange(of: model.lastLanded) {
                guard let landed = model.lastLanded,
                      cards.contains(where: { $0.id == landed.cardID })
                else { return }
                withAnimation(reduceMotion ? nil : .default) {
                    proxy.scrollTo(landed.cardID, anchor: .center)
                }
            }
        }
        // What the reader can currently see of this list, which is what decides
        // whether the caret still has a card to point at. The `ScrollView`'s own
        // bounds are the viewport, not the content — a card whose centre leaves
        // this rectangle has scrolled out, and `PanelLayout.isDetached` says so.
        //
        // Only the column the panel opened from reports. The other four have
        // nothing to say about a caret that is not theirs, and four extra
        // rectangles arriving at one key is four chances to answer for the wrong
        // column.
        .anchorPreference(key: CaretAnchorKey.self, value: .bounds) { bounds in
            model.selectedCard?.column == column ? CaretAnchors(list: bounds) : CaretAnchors()
        }
    }

    private func draggable(_ card: Card) -> some View {
        CardView(card: card)
            .id(card.id)
            .onDrag {
                // An action closure, not a view builder: safe to record the
                // selection here, and it means starting a drag arms the console
                // for the card in hand.
                model.selectedCardID = card.id
                return NSItemProvider(object: card.id.uuidString as NSString)
            }
            // Moving a card is the app's only gesture, and it used to be a
            // teleport: the card vanished from one column and appeared in
            // another with no motion connecting the two.
            //
            // Gated by the `.animation(reduceMotion ? nil : …, value:
            // cards.map(\.id))` on the enclosing `LazyVStack`, which is the
            // animation that drives it: a card arriving or leaving *is* a
            // change to that value. Reduce motion turns it off there, once, for
            // every card in the column.
            .transition(
                .asymmetric(
                    insertion: .opacity.combined(with: .offset(x: -14)),
                    removal: .opacity.combined(with: .scale(scale: 0.97))
                ))
    }

    /// The groups, or `nil` when a single repository is selected.
    ///
    /// Decided by `groupByRepo` in ElliotModel, which is where the ordering and
    /// the orphan fallback are proven. This only asks.
    private var groups: [CardGroup]? {
        guard model.selectedRepoID == nil else { return nil }
        return groupByRepo(cards, repos: model.repos)
    }

    /// Deliberately carries no `dropDestination`.
    ///
    /// The drop target is the column and only the column. A drop onto a group
    /// header would have to mean "move this card to that repository", which is
    /// a write `BoardService` owns and a second path to a card's identity — the
    /// exact kind of silent second write path the app is built to avoid.
    private func groupHeader(_ group: CardGroup) -> some View {
        Button {
            if collapsed.contains(group.repoID) {
                collapsed.remove(group.repoID)
            } else {
                collapsed.insert(group.repoID)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: collapsed.contains(group.repoID) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                ConsoleLabel(text: group.repoName, tint: .secondary)
                Fact(text: "\(group.cards.count)", tint: Palette.quiet, small: true)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.top, 4)
        }
        .buttonStyle(.plain)
        // Singular written out, by the same function the column caption above
        // uses. It was written out here and *not* there, which is how the two
        // labels on one column came to disagree about "1 cards".
        .accessibilityLabel(
            BoardAccessibility.groupCaption(
                repoName: group.repoName, count: group.cards.count, column: column.displayName
            )
        )
    }

    /// An empty column used to be blank, which reads as broken rather than
    /// available.
    private var dropHint: some View {
        RoundedRectangle(cornerRadius: Metric.cardRadius)
            .strokeBorder(
                style: StrokeStyle(lineWidth: 1, dash: [4, 4])
            )
            .foregroundStyle(.quaternary)
            .frame(height: 56)
            .overlay {
                Text(hintText)
                    .font(Type.prose)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 6)
            }
    }

    /// An empty column should not invite a drop it will refuse. The tint stays
    /// quiet: the header above already carries the refusal in `Palette.refused`,
    /// and a second coloured refusal in one column is the dilution the palette
    /// guards against.
    private var hintText: String {
        if isRefused { return "Not this card" }
        if column == .backlog { return "No stories yet — ⌘N writes one" }
        return "Drop a card here"
    }

    private var cards: [Card] { model.cards(in: column) }

    /// What dropping the card in hand would do, or `nil` when nothing is
    /// selected.
    private var consequence: Consequence? {
        guard let card = model.selectedCard, card.column != column else { return nil }
        return Consequence.of(model.preview(card, to: column))
    }

    private var isRefused: Bool { consequence?.isRefused ?? false }

    private var captionTint: Color {
        guard let consequence else { return .secondary }
        return consequence.isRefused ? Palette.refused : consequence.tint
    }

    /// `consequence` is `nil` for the card's *own* column, so both of these
    /// fell through to `Palette.armed` — dragging a card over the column it is
    /// already in painted that column in the app's most loaded colour, and then
    /// the drop was refused with "Already here." `Palette.inert` is the
    /// documented "nothing happens on arrival" tone and the standing rail tint
    /// of Backlog and In Review, so no accent is added here.
    private var background: some ShapeStyle {
        if isTargeted { return AnyShapeStyle(Surface.wash(consequence?.tint ?? Palette.inert)) }
        if isRefused { return AnyShapeStyle(Surface.recessFaint) }
        return AnyShapeStyle(Surface.recess)
    }

    private var borderTint: Color {
        if isTargeted { return consequence?.tint ?? Palette.inert }
        guard let consequence, !consequence.isRefused else { return .clear }
        return Surface.washBorder(consequence.tint)
    }
}

// MARK: - What a screen reader hears of the board

/// The sentences the board says aloud, as pure functions.
///
/// Same reason `LogRowAccessibility` exists one file over: a label written
/// inline in a `body` is a claim nothing can hold. `swift test` cannot see the
/// screen, but these it can see — and #79 asks for the five column captions to
/// still be there *after* a panel was inserted between them, which is a claim
/// worth being able to make.
///
/// Singular is written out in both captions here. "1 cards" is the kind of thing
/// that makes a careful product look careless, and these strings are read aloud.
/// The group header had already been fixed for exactly that and the column
/// caption above it had not — which is the argument for one function rather than
/// two spellings.
enum BoardAccessibility {

    /// A column's caption: its name, how many cards are in it, and either the
    /// consequence of dropping the card in hand or the column's standing rule.
    ///
    /// The caller decides which of those two `rule` is — that choice is
    /// `Consequence.of(model.preview(…))`, the same call the visible caption
    /// makes, and duplicating it here would be a second answer to it.
    static func columnCaption(name: String, count: Int, rule: String) -> String {
        "\(name), \(count) \(cards(count)). \(rule)"
    }

    /// A repository group inside a column, when the picker says "All
    /// repositories".
    static func groupCaption(repoName: String, count: Int, column: String) -> String {
        "\(repoName), \(count) \(cards(count)) in \(column)"
    }

    /// What the detail panel announces itself as.
    ///
    /// It names the column as well as the card, and that is the whole point of
    /// the sentence. A sighted reader learns which column the panel belongs to
    /// from the caret, the tether and the rail across its top — all three of
    /// which are `.accessibilityHidden(true)`, because they are decoration for a
    /// relationship that has to be *stated* rather than drawn. This is the
    /// statement. Drop the column from it and a listener has no way left to
    /// learn it.
    ///
    /// Applied in `DetailPanelView`, not here, and that is not arbitrary: the
    /// label VoiceOver uses is the one nearest the view, so a second one
    /// attached out here would be silently inert. It lives in this file only
    /// because it is a sentence a test can hold, next to the other two.
    static func panelLabel(title: String, column: ElliotModel.Column) -> String {
        "Details for \(title), in \(column.displayName)"
    }

    private static func cards(_ count: Int) -> String {
        count == 1 ? "card" : "cards"
    }
}
