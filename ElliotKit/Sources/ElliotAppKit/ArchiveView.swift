import ElliotModel
import SwiftUI

/// What the archive has loaded, and whether there is more of it.
///
/// A value rather than three `@State` properties on the view, because the
/// paging arithmetic is a decision and a decision in a `body` is a rule nothing
/// can prove. The view owns *when* to load; this owns *what has been loaded*.
struct ArchiveState: Equatable, Sendable {
    /// One screenful and a bit. Small enough that the first page is instant on
    /// a board of any size, large enough that nobody pages through a normal
    /// week's work.
    static let pageSize = 25

    private(set) var cards: [Card] = []
    /// Rows the current filter matches in total, which is the only thing that
    /// can say whether another page exists.
    private(set) var total = 0
    private(set) var search = ""

    /// Read off `cards` rather than accumulated, so a page that arrives twice —
    /// a re-entrant load, a view that reappears — cannot walk the offset past
    /// rows nobody has seen.
    var loaded: Int { cards.count }

    var canLoadMore: Bool { loaded < total }

    /// Appends a page and records what the same filter matched overall.
    mutating func append(_ page: [Card], total: Int) {
        cards += page
        self.total = total
    }

    /// Restarts paging under a new term.
    ///
    /// Inert when the term has not actually changed: `.task(id:)` fires on
    /// appearance as well as on change, and resetting there would blank the
    /// window every time it regained focus.
    ///
    /// `total` is cleared along with the rows. Keeping it would offer a "Load
    /// more" against a filter that no longer applies.
    mutating func setSearch(_ term: String) {
        guard term != search else { return }
        search = term
        cards = []
        total = 0
    }
}

/// Everything that has ever reached Done.
///
/// The board draws a horizon over that column and counts what it hid; this is
/// where the hidden part lives. Deliberately a plain reader: nothing here moves
/// a card, and there is no archive *state* to get into — a card in this window
/// is an ordinary finished card that the board is simply not drawing today.
///
/// `public` only because `ElliotApp` names it in a `Scene`.
public struct ArchiveView: View {
    public init() {}

    @Environment(AppModel.self) private var model
    @State private var state = ArchiveState()
    @State private var query = ""
    @State private var isLoading = false

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if state.cards.isEmpty {
                    emptyState
                } else {
                    // No horizon: the archive is the whole history, which is
                    // the case this parameter exists for.
                    ForEach(shippingLog(state.cards, now: Date(), calendar: .current, horizonDays: nil).days) { day in
                        ShipDayHeader(
                            label: day.label,
                            count: day.cards.count,
                            collapsed: false,
                            onToggle: {}
                        )
                        ForEach(day.cards) { card in
                            CardView(card: card)
                        }
                    }
                    if state.canLoadMore {
                        loadMoreButton
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Archive")
        .searchable(text: $query, prompt: "Search finished work")
        .task(id: query) {
            // A keystroke should not cost a query. Cancellation does the rest:
            // `.task(id:)` tears the old one down when `query` changes again.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            state.setSearch(query)
            if state.cards.isEmpty { await loadMore() }
        }
        .toolbar {
            ToolbarItem(placement: .status) {
                Fact(text: summary, tint: Palette.quiet, small: true)
            }
        }
    }

    /// Says which of the two empty states this is. "No results" and "nothing
    /// has shipped yet" are different facts, and answering a search with the
    /// second would read as the archive being broken.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.search.isEmpty ? "Nothing has reached Done yet." : "No finished card matches “\(state.search)”.")
                .font(Type.prose)
                .foregroundStyle(.secondary)
            if !state.search.isEmpty {
                Text("Search covers the title, the body, and the issue or pull request number.")
                    .font(Type.prose)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 8)
    }

    private var loadMoreButton: some View {
        Button {
            Task { await loadMore() }
        } label: {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView().controlSize(.small)
                }
                ConsoleLabel(text: isLoading ? "Loading" : "Load more")
                Fact(text: "\(state.total - state.loaded) left", tint: Palette.quiet, small: true)
            }
            .contentShape(Rectangle())
            .padding(.top, 6)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }

    private var summary: String {
        state.total == 0
            ? ""
            : "\(state.loaded) of \(state.total) shown"
    }

    /// Guarded rather than queued: two overlapping loads would both read the
    /// same offset and append the same page twice.
    private func loadMore() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let page = await model.archivePage(
            search: state.search,
            limit: ArchiveState.pageSize,
            offset: state.loaded
        )
        state.append(page.cards, total: page.total)
    }
}
