import ElliotModel
import Foundation

/// The archive's reading state, and the sequencing around it.
///
/// `ArchiveState` already owned *what has been loaded*; this owns *what is being
/// asked and how the answers are sequenced* — the term, the paging generation,
/// whether a read is in flight, whether one has ever finished, and which days
/// the reader has folded. `ArchiveView` keeps only "when to load".
///
/// **Why it is not six `@State` properties on the view (#230).** Two reasons,
/// and only one of them is the test.
///
/// 1. *No test could reach the seam.* The two ends were pinned — `ArchiveState`
///    has a suite, and `archivePage` has one — while the wire between them,
///    `query → .task(id: ArchiveQuery) → reload()`, had none and could have
///    none: `query` was `@State` and `reload()` was `private` over four more.
///    Inverting or truncating the three-input re-read key left 1 418 tests
///    green. It is ordinary code now, so the key is asserted and the generation
///    guard is covered.
/// 2. *A view's state dies with the view.* Hiding a board slot removes it from
///    `PanelLayout.boardOrder` and tears the subtree down. `AppModel` records
///    what that cost the analysis panel — four fields had to move here after a
///    hide was found to be lossy "in exactly the way this feature says it is
///    not", and the test that "proved" the hide was safe only ever looked at the
///    half that already lived on the model. The archive holds a *typed search
///    term* and *loaded pages*; both would go the day it stops being a window.
///
/// The page source is passed **per call** rather than held. A reader that owned
/// a closure back into `AppModel` would be a retain cycle to reason about, and —
/// more to the point — a test would have to build an `AppModel` to drive
/// paging. Handing the source in means a test hands in a stub and the sequencing
/// is exercised on its own.
@Observable
@MainActor
final class ArchiveReader {

    /// Reads one page: search term, limit, offset. `nil` means **could not
    /// look**, which is not the same as "there is nothing" — the distinction
    /// `archivePage` documents, and the reason `hasLoaded` is not set on a nil.
    typealias PageSource = @MainActor (String, Int, Int) async -> (cards: [Card], total: Int)?

    /// What the reader typed. Settable, which is the point: on the model it can
    /// be driven by a test, and by anything else that can reach the model.
    var query: String = ""

    /// Which shipping days are folded.
    ///
    /// Here rather than in the view because a fold is something the reader
    /// expressed, and because Done's own tail draws the same days — one owner is
    /// what stops the two disagreeing about a folded day.

    private(set) var state = ArchiveState()
    private(set) var isLoading = false

    /// Whether a load has ever *finished*.
    ///
    /// Without it the archive asserts "Nothing has reached Done yet." before it
    /// has asked anything. Saying "there is none" when the answer is "I have not
    /// looked" is the failure this project keeps paying for.
    private(set) var hasLoaded = false

    /// Bumped by every change of filter. A page that comes back carrying a stale
    /// generation is dropped rather than appended.
    ///
    /// `isLoading` alone was not enough and the difference is a real defect:
    /// typing while a "Load more" was in flight cleared the rows, found
    /// `isLoading` still true, returned without asking for anything — and then
    /// the in-flight page landed in the freshly cleared state. The archive then
    /// showed page two of the *previous* filter under the new term, with nothing
    /// scheduled to correct it.
    private var generation = 0

    init() {}

    /// Everything the archive's answer depends on.
    ///
    /// A key for `.task(id:)`, so that any of the three changing re-reads.
    /// Written out as a type rather than a tuple because `.task(id:)` needs
    /// `Equatable` and the point is that *all three* participate — a reader
    /// adding a fourth input to `archivePage` should have to come here.
    ///
    /// Reachable, and that is the whole of #230's first payoff: this was
    /// `private` to the view, so nothing could assert that truncating it goes
    /// red.
    struct Query: Equatable, Sendable {
        var search: String
        var repoID: UUID?
        var cardCount: Int

        init(search: String, repoID: UUID?, cardCount: Int) {
            self.search = search
            self.repoID = repoID
            self.cardCount = cardCount
        }
    }

    /// The key for the current term and the board state handed in.
    ///
    /// - `repoID`, because `archivePage` reads it: the picker moving otherwise
    ///   left the old repository's rows on screen, and the next page would be
    ///   queried for the *new* repository at the old offset — a summary reading
    ///   "25 of 3 shown" over another repository's cards.
    /// - `cardCount`, because a card can be deleted from its context menu and
    ///   `state.cards` is a snapshot that observes nothing. It also self-heals
    ///   the launch case: the store opens, the count goes 0 → N, and the read
    ///   that was too early runs again.
    func query(repoID: UUID?, cardCount: Int) -> Query {
        Query(search: query, repoID: repoID, cardCount: cardCount)
    }

    /// Starts the filter over: clears the rows and reads the first page.
    ///
    /// Bumps the generation **before** clearing, so a page still in flight for
    /// the previous filter is discarded when it lands instead of being appended
    /// to a result set it does not belong to.
    func reload(from source: PageSource) async {
        generation += 1
        state.setSearch(query)
        state.clear()
        await load(generation: generation, from: source)
    }

    /// Reads the next page under the current filter.
    ///
    /// `isLoading` guards a double-tap on "Load more" — two loads at the same
    /// offset would append the same page twice. It deliberately does *not* guard
    /// a filter change: that is the generation's job, and conflating the two is
    /// what let a stale page land in a cleared list.
    func loadMore(from source: PageSource) async {
        guard !isLoading else { return }
        await load(generation: generation, from: source)
    }

    /// `""` when there is nothing to summarise, so the caller draws nothing.
    var summary: String {
        state.total == 0 ? "" : "\(state.loaded) of \(state.total) shown"
    }

    private func load(generation mine: Int, from source: PageSource) async {
        isLoading = true
        defer { isLoading = false }

        let page = await source(state.search, ArchiveState.pageSize, state.loaded)

        // A newer filter superseded this read while it was in flight.
        guard mine == generation else { return }
        // `nil` is "could not look", not "there is nothing" — leave `hasLoaded`
        // alone so the archive says nothing rather than asserting an empty one
        // it never confirmed.
        guard let page else { return }

        state.append(page.cards, total: page.total)
        hasLoaded = true
    }
}
