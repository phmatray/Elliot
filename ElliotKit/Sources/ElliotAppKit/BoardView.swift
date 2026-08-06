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
            .disabled(model.selectedRepoID == nil || isSelectedRepoBlocked)
            .help(analyseHelp)
        }

        ToolbarItem {
            // A Button, not a Toggle. As a Toggle it read `showingInspector`,
            // so the toolbar re-vended its items in the middle of the split
            // view's own collapse animation — the crash in #50. There is no
            // split view any more, but the Button is still the right shape:
            // the panel being on screen is its own state indicator.
            Button {
                model.showingInspector.toggle()
            } label: {
                Label("Details", systemImage: "sidebar.right")
            }
            .disabled(model.selectedCard == nil)
            .help("Show or hide the selected card's details")
        }

        ToolbarItem {
            Button {
                openWindow(id: "repositories")
            } label: {
                Label("Repositories", systemImage: "square.stack.3d.up")
            }
            .help("Every repository of your accounts, and what is wrong with it")
        }

        ToolbarItem {
            Button {
                openWindow(id: "preflight")
            } label: {
                Label("Preflight", systemImage: "checkmark.seal")
            }
            .help("Check the tools and repositories Elliot depends on")
        }
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
        // Clicking the board's own background clears the selection, so the
        // console goes quiet without hunting for a close button. It fires by
        // bubbling — from a column's empty space and from the padding ring —
        // which is why the panel, now inside this container, absorbs its own.
        .contentShape(Rectangle())
        .onTapGesture { model.selectedCardID = nil }
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

    /// The detail panel, as one slot of the row.
    private func panel(width: CGFloat) -> some View {
        DetailPanelView(columnWidth: width)
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

        withAnimation(reduceMotion ? nil : .default) {
            boardScroll.scrollTo(x: offset)
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
        .accessibilityLabel("\(column.displayName), \(cards.count) cards. \(consequence?.summary ?? column.standingRule)")
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
        // Singular written out. "1 cards" is the kind of thing that makes a
        // careful product look careless, and this label is read aloud.
        .accessibilityLabel(
            "\(group.repoName), \(group.cards.count) \(group.cards.count == 1 ? "card" : "cards") in \(column.displayName)"
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
