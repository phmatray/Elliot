import ElliotEngine
import ElliotModel
import SwiftUI
import UniformTypeIdentifiers

public struct BoardView: View {
    @Environment(AppModel.self) private var model
    @State private var showingNewCard = false
    @State private var showingInspector = true

    public init() {}

    public var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            if model.repos.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    columns
                    if showingInspector, model.selectedCard != nil {
                        Divider()
                        InspectorView()
                            .frame(width: Metric.inspectorWidth)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            Divider()
            StatusBar()
        }
        .animation(.snappy(duration: 0.22), value: model.selectedCardID)
        .toolbar { toolbarContent }
        .navigationTitle("Elliot")
        .sheet(isPresented: $showingNewCard) {
            NewCardSheet(repoID: model.selectedRepoID ?? model.repos.first?.id)
        }
        .sheet(item: $model.pendingFollowUps) { pending in
            FollowUpSheet(pending: pending)
        }
        // The board keeps focus so a card can be moved without the mouse.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.escape) {
            guard model.selectedCardID != nil else { return .ignored }
            model.selectedCardID = nil
            return .handled
        }
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
                showingNewCard = true
            } label: {
                Label("New story", systemImage: "plus")
            }
            .disabled(model.repos.isEmpty)
            .help("Write a new backlog story (⌘N)")
            .keyboardShortcut("n")
        }

        ToolbarItem {
            Button {
                showingInspector.toggle()
            } label: {
                Label("Details", systemImage: "sidebar.right")
            }
            .disabled(model.selectedCard == nil)
            .help("Show or hide the selected card's details")
        }

        ToolbarItem {
            NavigationLink {
                PreflightView()
            } label: {
                Label("Preflight", systemImage: "checkmark.seal")
            }
            .help("Check the tools and repositories Elliot depends on")
        }
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
                    withAnimation { proxy.scrollTo(card.column, anchor: .center) }
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
}

// MARK: - Status bar

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            if !model.isReady {
                ProgressView().controlSize(.small)
            }
            Text(model.status)
                .font(Type.prose)
                .foregroundStyle(.secondary)

            Spacer()

            if !model.activeRuns.isEmpty {
                Fact(
                    text: "\(model.activeRuns.count) running",
                    tint: Palette.armed,
                    small: true
                )
            }
            if model.selectedCard != nil {
                Text("⌘→ advance · ⌘← back · esc deselect")
                    .font(Type.factSmall)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: - Column

struct ColumnView: View {
    @Environment(AppModel.self) private var model
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
            Task { await model.move(cardID: id, to: column) }
            return true
        } isTargeted: { targeted in
            // The refusal is stated in the header the whole time a card is
            // selected, so a refused column simply does not light up.
            isTargeted = targeted && !isRefused
        }
        .animation(.snappy(duration: 0.18), value: isTargeted)
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
                Fact(text: "\(cards.count)", small: true)
                    .foregroundStyle(.tertiary)
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
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(cards) { card in
                    CardView(card: card)
                        .onDrag {
                            // An action closure, not a view builder: safe to
                            // record the selection here, and it means starting
                            // a drag arms the console for the card in hand.
                            model.selectedCardID = card.id
                            return NSItemProvider(object: card.id.uuidString as NSString)
                        }
                }

                if cards.isEmpty {
                    dropHint
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollBounceBehavior(.basedOnSize)
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
                Text(column == .backlog ? "Nothing here yet" : "Drop a card here")
                    .font(Type.prose)
                    .foregroundStyle(.tertiary)
            }
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

    private var background: some ShapeStyle {
        if isTargeted { return AnyShapeStyle((consequence?.tint ?? Palette.armed).opacity(0.12)) }
        if isRefused { return AnyShapeStyle(Color.secondary.opacity(0.03)) }
        return AnyShapeStyle(Color.secondary.opacity(0.07))
    }

    private var borderTint: Color {
        if isTargeted { return consequence?.tint ?? Palette.armed }
        guard let consequence, !consequence.isRefused else { return .clear }
        return consequence.tint.opacity(0.45)
    }
}
