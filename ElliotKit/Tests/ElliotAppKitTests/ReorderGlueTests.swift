import ElliotEngine
import ElliotModel
import ElliotStore
import Foundation
import TestSupport
import Testing

@testable import ElliotAppKit

/// Records what the board asked for without spawning anything.
private actor FakeLauncher: RunLaunching {
    private(set) var launched: [UUID] = []

    func launch(runID: UUID) async { launched.append(runID) }
    func cancel(runID: UUID) async {}
    func launchedRuns() -> [UUID] { launched }
}

/// The step between two tested ends.
///
/// #49 wired the board's per-card drop target to `AppModel.reorder`, and its
/// Task 3 left five checks to a manual pass because "no test can see it". Three
/// of the five are not gestures at all — they are rules about what `reorder`
/// does *around* the arithmetic, and this suite is where they become
/// re-runnable instead of waiting on a permission nobody on this machine holds:
///
/// | #49 step | claim |
/// |---|---|
/// | 15 | a cross-column drop onto a position still performs the column move |
/// | 16 | a refused cross-column move places nothing |
/// | 17 | the chosen order reaches the store, so it survives a relaunch |
///
/// The two that genuinely need a drag — that the column-level drop still
/// receives drops on empty space and on an empty column's hint — are hit
/// testing, and they stay manual. Nothing here pretends otherwise.
///
/// `CardReorder.placement` is deliberately **not** re-tested here;
/// `CardReorderTests` owns that arithmetic purely and this suite would only be a
/// worse copy of it. What is tested is the glue, which is where the caret defect
/// of #159 also lived: both ends green, the step between them unmeasured.
@MainActor
@Suite("Reorder glue")
struct ReorderGlueTests {

    private struct Fixture {
        var store: BoardStore
        var launcher: FakeLauncher
        var model: AppModel
        var cards: [Card]

        /// Cards are looked up by title rather than held in `let`s at the call
        /// site: their `repoID` is a foreign key, so they cannot be minted until
        /// the fixture's repository exists.
        func card(_ title: String) throws -> Card {
            try #require(cards.first { $0.title == title })
        }
    }

    private static let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    private static func card(
        repoID: UUID, _ title: String, column: ElliotModel.Column, order: Double
    ) -> Card {
        Card(
            repoID: repoID, title: title,
            story: UserStory(
                role: "someone triaging a backlog", want: "to choose the order",
                benefit: "the column means something I chose"),
            column: column, orderIndex: order,
            columnEnteredAt: epoch, createdAt: epoch, updatedAt: epoch)
    }

    /// Builds a model with a **real** board and the **real** card observation
    /// behind it, runs `body`, and shuts the observation down.
    ///
    /// Every other `AppModel` fixture leaves `board` nil on purpose, which for
    /// `reorder` would mean asserting against a method that returns on its first
    /// line — a green test for a body that never ran.
    ///
    /// The observation is not optional decoration. `reorder`'s cross-column
    /// guard reads `cards`, whose only writer is that pump, so a fixture without
    /// one reports the placement as lost **by construction** — measured, and it
    /// is why this is wired up rather than stubbed.
    ///
    /// `enabled: false` is the refusal case: it produces the same `repoDisabled`
    /// block a repository Preflight has rejected does, which is what the board
    /// draws as "Repository blocked — see Preflight".
    private static func withBoard(
        enabled: Bool = true,
        build: (UUID) -> [Card],
        _ body: (Fixture) async throws -> Void
    ) async throws {
        let store = try BoardStore.inMemory()
        let launcher = FakeLauncher()
        let board = BoardService(store: store, launcher: launcher)

        var repo = Repo(
            path: "/tmp/reorder-\(UUID().uuidString)",
            nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        repo.permissionMode = .bypassPermissions
        repo.isEnabled = enabled
        try await store.saveRepo(repo)

        let cards = build(repo.id)
        for card in cards { try await store.saveCard(card) }

        let model = AppModel()
        model.testOnlySeedStore(store)
        model.testOnlyAttachBoard(board)
        model.observe(store: store)

        // Bounded, and on the value rather than the clock: the board has been
        // observing since `start()` long before any drag, so a test that raced
        // the first delivery would be measuring its own set-up.
        try await withTimeout(.seconds(10)) {
            while await MainActor.run(body: { model.cards.count }) != cards.count {
                try await Task.sleep(for: .milliseconds(5))
            }
        }

        let fixture = Fixture(store: store, launcher: launcher, model: model, cards: cards)
        do {
            try await body(fixture)
        } catch {
            await model.shutdown()
            throw error
        }
        await model.shutdown()
    }

    private static func order(_ store: BoardStore, _ id: UUID) async throws -> Double? {
        try await store.card(id: id)?.orderIndex
    }

    /// Three cards: one waiting in Backlog, two already in To Do.
    private static func withCrossColumnBoard(
        enabled: Bool, _ body: (Fixture) async throws -> Void
    ) async throws {
        try await withBoard(
            enabled: enabled,
            build: { repoID in
                [
                    card(repoID: repoID, "moving", column: .backlog, order: 10),
                    card(repoID: repoID, "first", column: .todo, order: 100),
                    card(repoID: repoID, "second", column: .todo, order: 200),
                ]
            }, body)
    }

    // MARK: - Step 15 — a cross-column drop still performs the move

    /// The half of criterion 2 that carries every consequence: dropping a card
    /// from another column onto a *position* must still file the issue. Had the
    /// drop target answered the placement itself, the card would slide into To Do
    /// having run nothing — a board that looks exactly like it worked.
    @Test("A cross-column drop performs the column move, and runs what the column promises")
    func crossColumnDropStillMoves() async throws {
        try await Self.withCrossColumnBoard(enabled: true) { f in
            let moving = try f.card("moving")
            let second = try f.card("second")

            await f.model.reorder(cardID: moving.id, in: .todo, above: second)

            #expect(
                try await f.store.card(id: moving.id)?.column == .todo,
                "the column move must happen")
            // Named, not counted. "A run started" would still pass if the drop
            // had triggered the wrong skill, and the whole point of the column
            // is *which* act it performs.
            let launched = await f.launcher.launchedRuns()
            #expect(launched.count == 1, "To Do files an issue — a run must start")
            let runID = try #require(launched.first)
            #expect(
                try await f.store.run(id: runID)?.kind == .createIssue,
                "and the act is the one To Do promises: create-issue")
            #expect(
                try await Self.order(f.store, moving.id) == 150,
                "and it lands where it was dropped: between first(100) and second(200)")
        }
    }

    // MARK: - Step 16 — a refused move places nothing

    /// The other half of criterion 2, and the one with a silent failure mode: a
    /// refused move that still wrote a placement would leave the card in its old
    /// column at a new index — a data change from a gesture the board has just
    /// told the user it declined.
    @Test("A refused cross-column move places nothing and leaves the card where it was")
    func refusedCrossColumnDropPlacesNothing() async throws {
        try await Self.withCrossColumnBoard(enabled: false) { f in
            let moving = try f.card("moving")
            let second = try f.card("second")

            await f.model.reorder(cardID: moving.id, in: .todo, above: second)

            #expect(
                try await f.store.card(id: moving.id)?.column == .backlog,
                "the move was refused, so the card stays put")
            #expect(
                try await Self.order(f.store, moving.id) == 10,
                "a refused move must not write an orderIndex")
            #expect(await f.launcher.launchedRuns().isEmpty, "nothing may run")
        }
    }

    // MARK: - Step 17 — the placement is written, not merely drawn

    /// Criterion 1's second clause. A relaunch reads the store, so "survives a
    /// relaunch" is the claim that the index reached SQLite — asserted by reading
    /// it back rather than off the model's own array, which is the copy a
    /// relaunch throws away.
    @Test("A same-column placement is written to the store, so it outlives the process")
    func sameColumnPlacementPersists() async throws {
        try await Self.withBoard(build: { repoID in
            [
                Self.card(repoID: repoID, "a", column: .backlog, order: 100),
                Self.card(repoID: repoID, "b", column: .backlog, order: 200),
                Self.card(repoID: repoID, "c", column: .backlog, order: 300),
            ]
        }) { f in
            let a = try f.card("a")
            let b = try f.card("b")
            let c = try f.card("c")

            // Drop c between a and b.
            await f.model.reorder(cardID: c.id, in: .backlog, above: b)

            #expect(
                try await Self.order(f.store, c.id) == 150,
                "the midpoint of its new neighbours, read back from the database")
            #expect(try await Self.order(f.store, a.id) == 100, "no neighbour is renumbered")
            #expect(try await Self.order(f.store, b.id) == 200)

            // What a relaunch does: a fresh read, in the order the board draws.
            let redrawn = try await f.store.cards(column: .backlog).map(\.title)
            #expect(redrawn == ["a", "c", "b"], "the order a relaunch would paint")
        }
    }

    /// Criterion 3, at the layer that writes. `CardReorderTests` proves
    /// `placement` answers `.none`; this proves `reorder` *acts* on that answer
    /// by writing nothing, which is a different claim and the one that reaches
    /// disk.
    @Test("A card dropped on itself writes nothing at all")
    func selfDropWritesNothing() async throws {
        try await Self.withBoard(build: { repoID in
            [
                Self.card(repoID: repoID, "a", column: .backlog, order: 100),
                Self.card(repoID: repoID, "b", column: .backlog, order: 200),
            ]
        }) { f in
            let a = try f.card("a")
            let b = try f.card("b")

            await f.model.reorder(cardID: b.id, in: .backlog, above: b)

            #expect(try await Self.order(f.store, b.id) == 200, "not a trip to the bottom")
            #expect(try await Self.order(f.store, a.id) == 100)
        }
    }
}
