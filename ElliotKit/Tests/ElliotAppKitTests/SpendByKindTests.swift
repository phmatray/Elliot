import ElliotModel
import ElliotStore
import Foundation
import Testing

@testable import ElliotAppKit

private let epoch = Date(timeIntervalSince1970: 1_770_000_000)

/// #308: the Spending band was one number and a ceiling sentence, over an
/// aggregate nothing outside tests called.
///
/// `DaySpendTests` proves the pairing purely and `SpendAggregateTests` proves the
/// query; this proves the model reads both halves at one boundary, and that a
/// column's caveat comes from the runs the reader can see going above it.
@MainActor
@Suite("What today's spend went on")
struct SpendByKindTests {

    private func store() throws -> BoardStore { try BoardStore.inMemory() }

    private func repo(_ store: BoardStore) async throws -> Repo {
        let repo = Repo(
            path: "/tmp/Elliot", nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        try await store.saveRepo(repo)
        return repo
    }

    @discardableResult
    private func finishedRun(
        _ store: BoardStore, _ repo: Repo, kind: SkillKind, cost: Double?
    ) async throws -> SkillRun {
        let card = Card(
            repoID: repo.id, title: "c", columnEnteredAt: epoch, createdAt: epoch,
            updatedAt: epoch)
        try await store.saveCard(card)
        var run = SkillRun(
            cardID: card.id, repoID: repo.id, kind: kind, prompt: "x", cwd: "/tmp",
            logPath: "/tmp/a", stderrPath: "/tmp/b", createdAt: Date())
        run.state = .succeeded
        run.endedAt = Date()
        run.totalCostUSD = cost
        try await store.saveRun(run)
        return run
    }

    private func goingRun(kind: SkillKind) -> SkillRun {
        var run = SkillRun(
            cardID: kind == .analyzeRepo ? nil : UUID(), repoID: UUID(),
            analysisID: kind == .analyzeRepo ? UUID() : nil, kind: kind, prompt: "x",
            cwd: "/tmp", logPath: "/tmp/a", stderrPath: "/tmp/b", createdAt: Date())
        run.state = .running
        run.startedAt = Date()
        return run
    }

    /// The whole of the day's reading arrives together, and the total is derived
    /// from it rather than assigned beside it — the arrangement where one is
    /// refreshed and the other is not.
    @Test("Refreshing reads the total and the split as one reading")
    func refreshReadsBothHalves() async throws {
        let model = AppModel()
        let store = try store()
        let repo = try await repo(store)
        try await finishedRun(store, repo, kind: .createIssue, cost: 0.5)
        try await finishedRun(store, repo, kind: .analyzeRepo, cost: 4)
        try await finishedRun(store, repo, kind: .analyzeRepo, cost: 6)
        model.testOnlySeedStore(store)

        await model.refreshSpend()

        #expect(model.daySpend.since == Calendar.current.startOfDay(for: Date()))
        #expect(model.spentToday.totalUSD == 10.5)
        #expect(model.daySpend.spend(.analyzeRepo).totalUSD == 10)
        #expect(model.daySpend.spend(.createIssue).totalUSD == 0.5)
        #expect(model.daySpend.spend(.mergePR) == .nothing)
    }

    /// The day total is what the columns add up to. Two `startOfDay(for: Date())`
    /// calls, one per query, would put them on two different days for whichever
    /// refresh straddles midnight — silently, on the one screen about money.
    @Test("The columns add up to the total, because both were asked the same question")
    func theSplitAddsUpToTheTotal() async throws {
        let model = AppModel()
        let store = try store()
        let repo = try await repo(store)
        try await finishedRun(store, repo, kind: .createIssue, cost: 1.25)
        try await finishedRun(store, repo, kind: .mergePR, cost: 2.75)
        model.testOnlySeedStore(store)

        await model.refreshSpend()

        let columns = model.todayByKind.reduce(0) { $0 + $1.figure.spend.totalUSD }
        #expect(columns == model.spentToday.totalUSD)
    }

    /// ⚠️ **Added because breaking `todayFigure` left the suite green.**
    ///
    /// Every other test here reads `spentToday` or `daySpend` — the values
    /// *behind* the screen. `todayFigure` is the one the status bar and the
    /// Spending band actually render, and its own doc comment says so
    /// (*"every screen showing the day's total reads this rather than
    /// `spentToday`"*). Replacing its `spend:` with `Spend.nothing` therefore
    /// showed `US$ 0.00` on every screen about money while all 2052 tests
    /// passed.
    ///
    /// `spentToday` being derived from `daySpend.total` makes *drift between the
    /// total and the split* unrepresentable, which is a real guarantee — but it
    /// is a different one from *the figure on screen is that total*, and only
    /// the first was held.
    @Test("The figure the screens render is the day's spend, not a fresh zero")
    func theRenderedFigureIsTheDaysSpend() async throws {
        let model = AppModel()
        let store = try store()
        let repo = try await repo(store)
        try await finishedRun(store, repo, kind: .createIssue, cost: 1.25)
        try await finishedRun(store, repo, kind: .mergePR, cost: 2.75)
        model.testOnlySeedStore(store)

        await model.refreshSpend()

        #expect(model.todayFigure.spend == model.spentToday)
        // Non-zero on purpose: `== spentToday` alone passes when both are zero,
        // which is exactly what the break produced.
        #expect(model.todayFigure.spend.totalUSD == 4)
        #expect(model.todayFigure.amount().contains("4"))
    }

    /// ⛔ The claim the column type exists for. Eight lenses in flight have ended
    /// nothing, so `spendByKind` returns nothing for them: without the in-flight
    /// count the analyze-repo column reads `$0.00` and *claims to be complete*
    /// for the whole hour the money is being spent.
    @Test("A skill whose runs are all still going does not read as free")
    func aSkillInFlightDoesNotReadAsFree() async throws {
        let model = AppModel()
        let store = try store()
        model.testOnlySeedStore(store)
        model.testOnlySeedRuns(recent: (0..<8).map { _ in goingRun(kind: .analyzeRepo) })

        await model.refreshSpend()

        let analyze = model.todayByKind.first { $0.kind == .analyzeRepo }!.figure
        #expect(analyze.spend == .nothing)
        #expect(!analyze.isComplete)
        #expect(analyze.inFlight == 8)
    }

    /// The in-flight count and the Running now band are the same selection, so
    /// the rows a reader can see are the rows the caveat is about. A queued run
    /// is in neither: it has spent nothing and is not going.
    @Test("What a column says is missing is what the band above it is drawing")
    func theCaveatMatchesTheBand() {
        let model = AppModel()
        var queued = goingRun(kind: .mergePR)
        queued.state = .queued
        queued.startedAt = nil
        model.testOnlySeedRuns(recent: [goingRun(kind: .mergePR), queued])

        #expect(model.runningNow.shown.count == 1)
        #expect(model.todayByKind.first { $0.kind == .mergePR }!.figure.inFlight == 1)
    }

    /// A store that cannot be read leaves a reading nobody took, not this
    /// morning's boundary over yesterday's figures.
    @Test("With no store behind the model there is no reading at all")
    func noStoreMeansNoReading() async {
        let model = AppModel()
        await model.refreshSpend()
        #expect(model.daySpend == .nothing)
        #expect(model.daySpend.since == .distantPast)
    }

    @Test("Every skill has a column, so a quiet one is a nought rather than a gap")
    func everySkillHasAColumn() {
        let model = AppModel()
        #expect(model.todayByKind.map(\.kind) == SkillKind.allCases)
    }
}
