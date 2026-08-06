import ElliotEngine
import ElliotModel
import SwiftUI
import UniformTypeIdentifiers

public struct BoardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @FocusState private var boardFocused: Bool

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
                columns
            }
            Divider()
            StatusBar()
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: model.selectedCardID)
        // The platform inspector, not a hand-rolled panel: the fixed 344 pt
        // frame forced the board to scroll on a laptop display whenever details
        // were open, and could not be dragged narrower.
        .inspector(isPresented: Binding(
            get: { model.showingInspector && model.selectedCard != nil },
            set: { model.showingInspector = $0 }
        )) {
            InspectorView()
                .inspectorColumnWidth(min: 300, ideal: Metric.inspectorWidth, max: 520)
        }
        .toolbar { toolbarContent }
        .navigationTitle("Elliot")
        .sheet(isPresented: $model.showingNewCard) {
            NewCardSheet(repoID: model.selectedRepoID ?? model.repos.first?.id)
        }
        .sheet(item: $model.pendingFollowUps) { pending in
            FollowUpSheet(pending: pending)
        }
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
                model.showingNewCard = true
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
            // A toggle, not a button: it has two states and the toolbar was
            // showing one icon for both.
            Toggle(isOn: Binding(
                get: { model.showingInspector },
                set: { model.showingInspector = $0 }
            )) {
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

    private var columns: some View {
        // The board has exactly five columns and always will — the rule engine
        // is a fixed transition matrix. So they share the width rather than
        // sitting at a fixed size that leaves Done half off-screen.
        GeometryReader { geometry in
            let count = CGFloat(ElliotModel.Column.allCases.count)
            let available = geometry.size.width - Metric.gutter * (count + 1)
            let width = max(Metric.minColumnWidth, available / count)

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: Metric.gutter) {
                        ForEach(ElliotModel.Column.allCases, id: \.self) { column in
                            ColumnView(column: column, width: width)
                                .id(column)
                        }
                    }
                    .padding(Metric.gutter)
                    .frame(minWidth: geometry.size.width, alignment: .leading)
                }
                .scrollDisabled(width > Metric.minColumnWidth)
                // In a window too narrow for five columns the board scrolls,
                // and the card you just selected could be the one off-screen.
                .onChange(of: model.selectedCardID) {
                    guard let card = model.selectedCard else { return }
                    withAnimation(reduceMotion ? nil : .default) {
                        proxy.scrollTo(card.column, anchor: .center)
                    }
                }
                // A second handler, because `nudgeSelection` never touches
                // `selectedCardID`: ⌘→ advanced a card into a column the board
                // did not follow it to. Kept separate from the handler above so
                // each comment stays true to what it covers.
                .onChange(of: model.selectedCard?.column) {
                    guard let card = model.selectedCard else { return }
                    withAnimation(reduceMotion ? nil : .default) {
                        proxy.scrollTo(card.column, anchor: .center)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
        // Clicking the board's own background clears the selection, so the
        // console goes quiet without hunting for a close button.
        .contentShape(Rectangle())
        .onTapGesture { model.selectedCardID = nil }
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

struct StatusBar: View {
    @Environment(AppModel.self) private var model

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

            Spacer()

            if !model.activeRuns.isEmpty {
                Fact(
                    text: "\(model.activeRuns.count) running",
                    tint: Palette.armed,
                    small: true
                )
            }
            // Elliot wrote this hint, so it is not set in the fact face.
            Text(model.selectedCard == nil
                ? "↑↓←→ pick a card"
                : "⌘→ advance · ⌘← back · esc deselect")
                .font(Type.prose)
                .foregroundStyle(Palette.quiet)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: - Column

struct ColumnView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let column: ElliotModel.Column
    let width: CGFloat
    @State private var isTargeted = false

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
                    ForEach(cards) { card in
                        CardView(card: card)
                            .id(card.id)
                            .onDrag {
                                // An action closure, not a view builder: safe
                                // to record the selection here, and it means
                                // starting a drag arms the console for the card
                                // in hand.
                                model.selectedCardID = card.id
                                return NSItemProvider(object: card.id.uuidString as NSString)
                            }
                            // Moving a card is the app's only gesture, and it
                            // used to be a teleport: the card vanished from one
                            // column and appeared in another with no motion
                            // connecting the two.
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .offset(x: -14)),
                                removal: .opacity.combined(with: .scale(scale: 0.97))
                            ))
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
