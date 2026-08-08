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

    /// Drops every loaded row, keeping the term.
    ///
    /// Separate from `setSearch` because a repository change or a deletion
    /// invalidates the rows without changing the term — and `setSearch` is
    /// deliberately inert on an unchanged term.
    mutating func clear() {
        cards = []
        total = 0
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

/// One day header the archive draws, and whether a page boundary may have cut
/// that day.
///
/// A named value rather than a tuple built inline in the `body`, because the
/// predicate that sets `partial` is the whole of what #162 changed on screen —
/// and inline in a `ViewBuilder` it was unreachable by any test. Code review
/// proved that concretely: inverting the flag, so every whole day was marked and
/// the cut one was not, left all 1415 tests green.
struct ShipDayRow: Equatable, Identifiable {
    /// The day's own identity, so the `ForEach` keys on exactly what it did
    /// before this type existed.
    var id: Date { day.id }
    var day: ShipDay
    var partial: Bool
}

extension ArchiveState {
    /// The loaded rows as day headers, each carrying whether its count is a
    /// floor rather than the day's total.
    ///
    /// `now` and `calendar` are parameters and not `.current`, for the reason
    /// `ShipDayHeader.text` gives: a rule tested against the ambient clock fails
    /// somewhere near midnight and in somebody else's timezone.
    ///
    /// No horizon — the archive is the whole history, which is the case that
    /// parameter exists for, and it is also what makes `partialDay` able to
    /// answer at all (it refuses a horizon-limited log by design).
    func dayRows(now: Date, calendar: Calendar) -> [ShipDayRow] {
        let log = shippingLog(cards, now: now, calendar: calendar, horizonDays: nil)
        let cut = log.partialDay(moreToLoad: canLoadMore)
        return log.days.map { ShipDayRow(day: $0, partial: $0.start == cut) }
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

    /// Everything this view used to hold in six `@State` properties, lifted onto
    /// the model by #230 — the term, the pages, the generation guard, whether a
    /// load has finished, and the folded days. The view keeps only *when* to
    /// load.
    private var reader: ArchiveReader { model.archive }

    public var body: some View {
        // A local `@Bindable` because `AppModel.archive` is a `let`: the
        // binding is to the reader's own property, not to the slot holding
        // it. The same shape `AnalysisPanelView` uses for its resize handle.
        @Bindable var archive = model.archive
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if reader.state.cards.isEmpty {
                    if reader.hasLoaded { emptyState }
                } else {
                    // In the content, not the toolbar.
                    //
                    // It was a `ToolbarItem(placement: .status)` and macOS drew
                    // it clipped — "25 of 44 shown" lost the leading digit to
                    // the capsule the toolbar wraps a status item in, and
                    // `.fixedSize()` did not stop it, because the width is the
                    // toolbar's to decide once the search field is expanded.
                    // Verified on screen twice, which is the only way this was
                    // ever going to be found.
                    Fact(text: reader.summary, tint: Palette.quiet, small: true)
                        .padding(.bottom, 2)
                    // Computed once per pass rather than inside the `ForEach`:
                    // `shippingLog` buckets and sorts every loaded card, and the
                    // cut day can only be named from the whole log, so asking
                    // per row would re-derive it once per day drawn.
                    ForEach(reader.state.dayRows(now: Date(), calendar: .current)) { row in
                        let day = row.day
                        ShipDayHeader(
                            label: day.label,
                            count: day.cards.count,
                            partial: row.partial,
                            collapsed: reader.isCollapsed(day.start)
                        ) {
                            reader.toggleDay(day.start)
                        }
                        if !reader.isCollapsed(day.start) {
                            ForEach(day.cards) { card in
                                CardView(card: card)
                            }
                        }
                    }
                    if reader.state.canLoadMore {
                        loadMoreButton
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Archive")
        .searchable(text: $archive.query, prompt: "Search finished work")
        // Keyed on everything the answer depends on, not just the search term.
        //
        // - `selectedRepoID`, because `archivePage` reads it: the picker moving
        //   while this window is open otherwise left the old repository's rows
        //   on screen, and the next page would then be queried for the *new*
        //   repository at the old offset — a summary reading "25 of 3 shown"
        //   over a list of another repository's cards.
        // - `model.cards.count`, because a card can be deleted from its context
        //   menu — including from this window — and `state.cards` is a snapshot
        //   that observes nothing. Without this the deleted row stayed on
        //   screen looking like the delete had failed, and every later page was
        //   off by one. It also self-heals the launch case: the store opens,
        //   the count goes 0 → N, and the read that was too early runs again.
        .task(id: reader.query(repoID: model.selectedRepoID, cardCount: model.cards.count)) {
            // A keystroke should not cost a query. Cancellation does the rest:
            // `.task(id:)` tears the old one down when the key changes again.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await reader.reload(from: model.archivePage(search:limit:offset:))
        }
    }

    /// Says which of the two empty states this is. "No results" and "nothing
    /// has shipped yet" are different facts, and answering a search with the
    /// second would read as the archive being broken.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(reader.state.search.isEmpty
                ? "Nothing has reached Done yet."
                : "No finished card matches “\(reader.state.search)”.")
                .font(Type.prose)
                .foregroundStyle(.secondary)
            if !reader.state.search.isEmpty {
                Text("Search covers the title, the body, and the issue or pull request number.")
                    .font(Type.prose)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 8)
    }

    private var loadMoreButton: some View {
        Button {
            Task { await reader.loadMore(from: model.archivePage(search:limit:offset:)) }
        } label: {
            HStack(spacing: 6) {
                if reader.isLoading {
                    ProgressView().controlSize(.small)
                }
                ConsoleLabel(text: reader.isLoading ? "Loading" : "Load more")
                Fact(text: "\(reader.state.total - reader.state.loaded) left", tint: Palette.quiet, small: true)
            }
            .contentShape(Rectangle())
            .padding(.top, 6)
        }
        .buttonStyle(.plain)
        .disabled(reader.isLoading)
    }

}
