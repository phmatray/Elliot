import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// The seam #230 says no test could reach.
///
/// Both ends were already pinned — `ArchiveState` has a suite and `archivePage`
/// has one — while the wire between them had none and *could* have none: the
/// term was `@State`, `reload()` was `private`, and the three-input re-read key
/// was a `private struct` inside the view. Inverting or truncating that key left
/// the whole suite green.
///
/// Every test here drives the reader with a stub page source, so the sequencing
/// is exercised without a store, a clock, or an `AppModel`.
@MainActor
@Suite("Archive reader")
struct ArchiveReaderTests {

    private func card(_ title: String) -> Card {
        let fixed = Date(timeIntervalSince1970: 1_754_600_000)
        return Card(
            repoID: UUID(), title: title, column: .done,
            columnEnteredAt: fixed, createdAt: fixed, updatedAt: fixed
        )
    }

    /// A source that answers from a script and records what it was asked.
    ///
    /// `@MainActor` because `ArchiveReader.PageSource` is a global-actor-isolated
    /// function type, which Swift 6 makes implicitly `@Sendable` — so a method
    /// reference on a non-isolated class cannot be handed in.
    @MainActor
    private final class Source {
        var answers: [(cards: [Card], total: Int)?]
        private(set) var calls: [(search: String, limit: Int, offset: Int)] = []

        init(_ answers: [(cards: [Card], total: Int)?]) { self.answers = answers }

        @MainActor
        func page(_ search: String, _ limit: Int, _ offset: Int) async
            -> (cards: [Card], total: Int)?
        {
            calls.append((search, limit, offset))
            return answers.isEmpty ? nil : answers.removeFirst()
        }
    }

    // MARK: - The re-read key

    /// AC2: all three inputs participate. Truncating the key — dropping any one
    /// of them — makes one of these three pairs compare equal, and the test says
    /// which.
    @Test("Every input of the re-read key changes it")
    func everyInputChangesTheKey() {
        let reader = ArchiveReader()
        let repo = UUID()
        reader.query = "search"

        let base = reader.query(repoID: repo, cardCount: 3)

        reader.query = "other"
        #expect(
            reader.query(repoID: repo, cardCount: 3) != base,
            "the search term is not in the key: typing would not re-read"
        )
        reader.query = "search"

        #expect(
            reader.query(repoID: UUID(), cardCount: 3) != base,
            "the repository is not in the key: moving the picker would leave the old rows"
        )
        #expect(
            reader.query(repoID: repo, cardCount: 4) != base,
            "the card count is not in the key: a delete would leave a phantom row"
        )
    }

    /// And the key does **not** change when nothing did — `.task(id:)` fires on
    /// appearance as well as on change, so an unstable key would re-read the
    /// archive every time the view came back.
    @Test("An unchanged board leaves the key alone")
    func unchangedBoardKeepsTheKey() {
        let reader = ArchiveReader()
        let repo = UUID()
        reader.query = "x"
        #expect(reader.query(repoID: repo, cardCount: 2) == reader.query(repoID: repo, cardCount: 2))
    }

    // MARK: - Paging

    @Test("A first read fills the state and offsets the next one")
    func firstReadPages() async {
        let source = Source([(cards: [card("a"), card("b")], total: 5)])
        let reader = ArchiveReader()

        await reader.reload(from: source.page)

        #expect(reader.state.loaded == 2)
        #expect(reader.state.total == 5)
        #expect(reader.state.canLoadMore)
        #expect(reader.hasLoaded)
        #expect(source.calls.first?.offset == 0)
        #expect(source.calls.first?.limit == ArchiveState.pageSize)
    }

    @Test("Load more asks at the loaded offset and appends")
    func loadMoreAppends() async {
        let source = Source([
            (cards: [card("a")], total: 3),
            (cards: [card("b")], total: 3),
        ])
        let reader = ArchiveReader()

        await reader.reload(from: source.page)
        await reader.loadMore(from: source.page)

        #expect(reader.state.loaded == 2)
        #expect(source.calls.count == 2)
        #expect(source.calls.last?.offset == 1)
    }

    // MARK: - The generation guard

    /// The defect the generation exists for, driven end to end.
    ///
    /// A page in flight for the previous filter must be **dropped** when it
    /// lands, not appended to a list the new filter has cleared. Against a
    /// reader that guarded only on `isLoading`, the stale page lands and the
    /// archive shows page two of the previous term under the new one.
    @Test("A page in flight for the previous filter is discarded, not appended")
    func staleePageIsDropped() async {
        let reader = ArchiveReader()

        // A source that lets the test interleave: the first call parks until
        // released, the second answers at once.
        @MainActor
        final class Gate {
            var released = false
        }
        let gate = Gate()
        let stale = [card("stale-1"), card("stale-2")]
        let fresh = [card("fresh")]

        @MainActor
        func source(_ search: String, _ limit: Int, _ offset: Int) async
            -> (cards: [Card], total: Int)?
        {
            if search.isEmpty {
                while !gate.released { await Task.yield() }
                return (cards: stale, total: 9)
            }
            return (cards: fresh, total: 1)
        }

        // Start the first read and let it park inside the source.
        reader.query = ""
        let first = Task { await reader.reload(from: source) }
        await Task.yield()

        // The filter changes and completes while the first is still parked.
        reader.query = "fresh"
        await reader.reload(from: source)

        gate.released = true
        await first.value

        #expect(
            reader.state.search == "fresh",
            "the term the state is paging under is not the one last asked for"
        )
        #expect(
            reader.state.cards.map(\.title) == ["fresh"],
            "a page from the previous filter was appended to the new one's results"
        )
        #expect(reader.state.total == 1)
    }

    // MARK: - Could not look

    /// `nil` is "could not look", not "there is nothing". Setting `hasLoaded` on
    /// a nil makes the archive assert an empty archive it never confirmed —
    /// which is the failure this project keeps paying for, one screen over.
    @Test("A read that could not look does not claim the archive is empty")
    func nilPageDoesNotClaimEmpty() async {
        let source = Source([nil])
        let reader = ArchiveReader()

        await reader.reload(from: source.page)

        #expect(!reader.hasLoaded, "a failed read reported an empty archive as a fact")
        #expect(reader.state.cards.isEmpty)
        #expect(reader.summary.isEmpty)
    }

    // MARK: - Folded days

    /// The fold moved off `ArchiveReader` in #315. It was one of two copies over
    /// the same `ShipDay.start` keys — Done held the other as a `@State` in
    /// `BoardView`, with the toggle written out verbatim in both — so folding a
    /// day on one surface left it open on the other, showing the same cards
    /// under the same heading.
    @Test("Folding a day is remembered, and folding it again undoes it")
    func foldingRoundTrips() {
        let model = AppModel()
        let day = Date(timeIntervalSince1970: 1_754_600_000)

        #expect(!model.isDayCollapsed(day))
        model.toggleDay(day)
        #expect(model.isDayCollapsed(day))
        model.toggleDay(day)
        #expect(!model.isDayCollapsed(day))
    }

    /// The claim the move exists to make true: one set, so the two surfaces a
    /// unified shell puts side by side cannot disagree about a day.
    ///
    /// ⛔ And the claim it must **not** make. `ColumnView`'s repository-group
    /// fold stays a separate set: a repository and a day are different things
    /// to have folded, and merging them would be this very drift one level up.
    @Test("Done and the Archive fold the same day, because there is one set")
    func oneFoldForBothSurfaces() {
        let model = AppModel()
        let day = Date(timeIntervalSince1970: 1_754_600_000)
        let other = Date(timeIntervalSince1970: 1_754_500_000)

        // Whichever surface toggles it, both read the same answer — there is
        // only one place for either of them to read.
        model.toggleDay(day)
        #expect(model.isDayCollapsed(day))
        #expect(!model.isDayCollapsed(other))
        #expect(model.collapsedDays == [day])
    }

    /// The reason the state is on the model at all: a hide destroys the view,
    /// and everything asserted here would go with it.
    @Test("The term, the pages and the folds all survive the view being destroyed")
    func stateSurvivesTheView() async {
        let model = AppModel()
        let source = Source([(cards: [card("a")], total: 4)])
        let day = Date(timeIntervalSince1970: 1_754_600_000)

        model.archive.query = "half-written search"
        model.toggleDay(day)
        await model.archive.reload(from: source.page)

        // Whatever a view did, the model still holds it — no view exists here at
        // all, which is the point.
        #expect(model.archive.query == "half-written search")
        #expect(model.isDayCollapsed(day))
        #expect(model.archive.state.loaded == 1)
        #expect(model.archive.summary == "1 of 4 shown")
    }

    @Test("An empty archive summarises as nothing rather than as a count of zero")
    func emptySummaryIsEmpty() {
        #expect(ArchiveReader().summary.isEmpty)
    }
}
