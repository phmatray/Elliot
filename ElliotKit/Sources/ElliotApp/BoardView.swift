import ElliotEngine
import ElliotModel
import SwiftUI
import UniformTypeIdentifiers

public struct BoardView: View {
    @Environment(AppModel.self) private var model
    @State private var draggingCardID: UUID?
    @State private var showingNewCard = false

    public init() {}

    public var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.repos.isEmpty {
                emptyState
            } else {
                columns
            }
            Divider()
            statusBar
        }
        .sheet(isPresented: $showingNewCard) {
            NewCardSheet(repoID: model.selectedRepoID ?? model.repos.first?.id)
        }
        .sheet(item: $model.pendingFollowUps) { pending in
            FollowUpSheet(pending: pending)
        }
    }

    private var toolbar: some View {
        @Bindable var model = model
        return HStack(spacing: 12) {
            Picker("Repository", selection: $model.selectedRepoID) {
                Text("All repositories").tag(UUID?.none)
                ForEach(model.repos) { repo in
                    Text(repo.displayName).tag(UUID?.some(repo.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 240)

            Button {
                showingNewCard = true
            } label: {
                Label("New story", systemImage: "plus")
            }
            .disabled(model.repos.isEmpty)

            Spacer()

            NavigationLink {
                PreflightView()
            } label: {
                Label("Preflight", systemImage: "checkmark.seal")
            }
        }
        .padding(12)
    }

    private var columns: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(ElliotModel.Column.allCases, id: \.self) { column in
                    ColumnView(column: column, draggingCardID: $draggingCardID)
                }
            }
            .padding(12)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No repository yet", systemImage: "folder.badge.plus")
        } description: {
            Text("Add a git repository to start filing stories against it.")
        } actions: {
            Button("Add a repository…") { chooseRepository() }
        }
        .frame(maxHeight: .infinity)
    }

    private var statusBar: some View {
        HStack {
            if !model.isReady { ProgressView().controlSize(.small) }
            Text(model.status)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.addRepo(path: url.path) }
    }
}

struct ColumnView: View {
    @Environment(AppModel.self) private var model
    let column: ElliotModel.Column
    @Binding var draggingCardID: UUID?
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(column.displayName).font(.headline)
                Text("\(cards.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if let hint = triggerHint {
                    Image(systemName: "bolt.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help(hint)
                }
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(cards) { card in
                        CardView(card: card)
                            .draggable(card.id.uuidString) {
                                CardView(card: card).frame(width: 260)
                            }
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 300)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(isTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            Task { await model.move(cardID: id, to: column) }
            return true
        } isTargeted: { isTargeted = $0 }
    }

    private var cards: [Card] { model.cards(in: column) }

    /// What arriving in this column sets off, so the consequence is visible
    /// before the card is dropped.
    private var triggerHint: String? {
        switch column {
        case .todo: "Arriving from Backlog files a GitHub issue."
        case .inProgress: "Arriving from To Do implements the issue and opens a PR."
        case .done: "Arriving from In Review merges the PR."
        case .backlog, .inReview: nil
        }
    }
}
