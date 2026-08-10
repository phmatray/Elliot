import ElliotEngine
import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import TestSupport
import Testing

@testable import ElliotAppKit

/// #334: the suppression table was write-only.
///
/// `deleteCard` wrote a row per number the card held, `GitHubImporter.plan`
/// skipped that unit for ever, and the only thing that could act on it was
/// *Forget dismissed items* — every dismissal for every repository in view, at
/// once. The two available answers to "I deleted the wrong card" were *live with
/// it* and *undo every deletion I have ever made here*.
///
/// What these assert is the third answer, and the two things it must not become:
/// a restore that creates a card, and a restore that forgets more than the one
/// row it was pressed on.
@Suite("Dismissed list")
@MainActor
struct DismissedListTests {

    private enum Paths {
        static let repoRoot: URL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ElliotAppKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ElliotKit
            .deletingLastPathComponent()   // repo root

        static let fakeGH = repoRoot.appendingPathComponent("Scripts/fake-gh.sh").path

        static func fixture(_ name: String) -> String {
            repoRoot.appendingPathComponent("Fixtures/gh/\(name)").path
        }
    }

    private actor SilentLauncher: RunLaunching {
        func launch(runID: UUID) async {}
        func cancel(runID: UUID) async {}
    }

    private func repo(_ name: String = "Elliot") -> Repo {
        Repo(
            path: "/tmp/elliot-\(UUID().uuidString)",
            nameWithOwner: "phmatray/\(name)", displayName: name)
    }

    /// A model with a real store behind it and no importer — enough for every
    /// claim that is about the table rather than about `gh`.
    private func seeded(_ repos: [Repo]) async throws -> (AppModel, BoardStore) {
        let store = try BoardStore.inMemory()
        for repo in repos { try await store.saveRepo(repo) }
        let model = AppModel()
        model.testOnlySeed(repos: repos, cards: [])
        model.testOnlySeedStore(store)
        return (model, store)
    }

    private func importer(_ store: BoardStore) -> GitHubImportService {
        GitHubImportService(
            store: store,
            gh: GHClient(config: ToolConfig(
                claudePath: "", ghPath: Paths.fakeGH, gitPath: "",
                environment: [
                    "FAKE_GH_ISSUES": Paths.fixture("issues-basic.json"),
                    "FAKE_GH_PRS": Paths.fixture("prs-basic.json"),
                ])),
            board: BoardService(store: store, launcher: SilentLauncher()))
    }

    // MARK: - 1. Criterion 2: one row, not the lot

    @Test("Restoring one dismissal leaves the card's other ref suppressed")
    func restoringOneLeavesTheSiblingRef() async throws {
        let one = repo()
        let (model, store) = try await seeded([one])
        model.selectedRepoID = one.id
        let issue = ExternalRef(kind: .issue, number: 102)
        let pr = ExternalRef(kind: .pullRequest, number: 201)
        try await store.dismiss(issue, repoID: one.id)
        try await store.dismiss(pr, repoID: one.id)

        let items = try await store.dismissedItems(repoID: one.id)
        let target = try #require(items.first { $0.ref == issue })
        await model.restoreDismissal(target)

        #expect(try await store.dismissals(repoID: one.id) == [pr])
    }

    /// A restore in one repository is not a restore in another, even when the
    /// number is the same — which for low issue numbers it very often is.
    @Test("Restoring reaches exactly one repository")
    func restoringReachesOneRepository() async throws {
        let one = repo("One")
        let two = repo("Two")
        let (model, store) = try await seeded([one, two])
        let ref = ExternalRef(kind: .issue, number: 3)
        try await store.dismiss(ref, repoID: one.id)
        try await store.dismiss(ref, repoID: two.id)

        let target = try #require(
            try await store.dismissedItems(repoID: one.id).first)
        await model.restoreDismissal(target)

        #expect(try await store.dismissals(repoID: one.id).isEmpty)
        #expect(try await store.dismissals(repoID: two.id) == [ref])
    }

    /// ⛔ The importer creates cards. A restore that inserted one would be the
    /// second write path `BoardService` exists to prevent, and it would insert a
    /// card carrying whatever the row remembered rather than what GitHub says
    /// today.
    @Test("Restoring creates no card: it deletes a row and waits for the refresh")
    func restoringCreatesNoCard() async throws {
        let one = repo()
        let (model, store) = try await seeded([one])
        try await store.dismiss(ExternalRef(kind: .issue, number: 4), repoID: one.id)
        let target = try #require(try await store.dismissedItems(repoID: one.id).first)

        await model.restoreDismissal(target)

        #expect(try await store.cards(repoID: one.id).isEmpty)
    }

    /// The row is gone, so pressing again cannot fail — the observation may not
    /// have redrawn the list yet, and the next refresh may already have brought
    /// the card back.
    @Test("Restoring the same row twice is not an error")
    func restoringTwiceIsHarmless() async throws {
        let one = repo()
        let (model, store) = try await seeded([one])
        try await store.dismiss(ExternalRef(kind: .issue, number: 4), repoID: one.id)
        let target = try #require(try await store.dismissedItems(repoID: one.id).first)

        await model.restoreDismissal(target)
        await model.restoreDismissal(target)
        #expect(try await store.dismissals(repoID: one.id).isEmpty)
    }

    // MARK: - 2. The restored item actually comes back

    /// The reason `clearDismissals` calls `importSession.forget` and the reason
    /// a restore must too: a repository whose one unattended attempt is already
    /// spent would not pick the item back up until the reader pressed Refresh —
    /// so *Restore* would appear to do nothing at all.
    ///
    /// Asserted through the consequence rather than through the private session:
    /// a second `importIfNeeded` that imports is an attempt that was given back.
    @Test("Restoring gives the repository its unattended import attempt back")
    func restoringRestoresTheUnattendedAttempt() async throws {
        let one = repo()
        let (model, store) = try await seeded([one])
        model.selectedRepoID = one.id
        let board = BoardService(store: store, launcher: SilentLauncher())
        model.testOnlyAttachImporter(importer(store))
        model.testOnlyAttachBoard(board)

        try await withTimeout(.seconds(30)) { await model.importIfNeeded(repoID: one.id) }
        #expect(try await store.cards(repoID: one.id).count == 3)

        let doomed = try #require(
            try await store.cards(repoID: one.id).first { $0.issueNumber == 101 })
        try await board.deleteCard(id: doomed.id)
        #expect(try await store.cards(repoID: one.id).count == 2)

        let target = try #require(
            try await store.dismissedItems(repoID: one.id).first { $0.ref.number == 101 })
        await model.restoreDismissal(target)

        try await withTimeout(.seconds(30)) { await model.importIfNeeded(repoID: one.id) }
        #expect(
            try await store.cards(repoID: one.id).contains { $0.issueNumber == 101 },
            "the attempt was still spent, so Restore did nothing a reader could see")
    }

    // MARK: - 3. Criterion 4: Forget dismissed items is untouched

    @Test("Forgetting still empties every repository in view")
    func clearDismissalsStillClearsThemAll() async throws {
        let one = repo("One")
        let two = repo("Two")
        let (model, store) = try await seeded([one, two])
        model.selectedRepoID = nil
        try await store.dismiss(ExternalRef(kind: .issue, number: 1), repoID: one.id)
        try await store.dismiss(ExternalRef(kind: .issue, number: 2), repoID: two.id)

        await model.clearDismissals()

        #expect(try await store.dismissedItems(repoID: nil).isEmpty)
    }

    @Test("Forgetting with one repository selected leaves the other's dismissals alone")
    func clearDismissalsFollowsThePicker() async throws {
        let one = repo("One")
        let two = repo("Two")
        let (model, store) = try await seeded([one, two])
        model.selectedRepoID = one.id
        try await store.dismiss(ExternalRef(kind: .issue, number: 1), repoID: one.id)
        try await store.dismiss(ExternalRef(kind: .issue, number: 2), repoID: two.id)

        await model.clearDismissals()

        #expect(try await store.dismissedItems(repoID: one.id).isEmpty)
        #expect(try await store.dismissedItems(repoID: two.id).count == 1)
    }

    // MARK: - 4. What the face and the door read

    @Test("The list follows the picker, grouped when the picker is on All")
    func visibleDismissalsFollowThePicker() async throws {
        let one = repo("One")
        let two = repo("Two")
        let (model, _) = try await seeded([one, two])
        model.testOnlySeedDismissals([
            DismissedItem(
                repoID: one.id, ref: ExternalRef(kind: .issue, number: 1),
                dismissedAt: Date(timeIntervalSince1970: 100)),
            DismissedItem(
                repoID: two.id, ref: ExternalRef(kind: .issue, number: 2),
                dismissedAt: Date(timeIntervalSince1970: 200)),
        ])

        model.selectedRepoID = nil
        #expect(model.visibleDismissals.map(\.repoID) == [two.id, one.id])

        model.selectedRepoID = one.id
        #expect(model.visibleDismissals.map(\.repoID) == [one.id])
        #expect(model.visibleDismissals.first?.rows.count == 1)
    }

    @Test("The door's figure counts what is in view, and is absent at zero")
    func dismissedFigureCountsWhatIsInView() async throws {
        let one = repo("One")
        let two = repo("Two")
        let (model, _) = try await seeded([one, two])
        #expect(model.dismissedFigure == nil, "nothing dismissed is no figure at all")

        model.testOnlySeedDismissals([
            DismissedItem(
                repoID: one.id, ref: ExternalRef(kind: .issue, number: 1), dismissedAt: .now),
            DismissedItem(
                repoID: one.id, ref: ExternalRef(kind: .pullRequest, number: 2),
                dismissedAt: .now),
            DismissedItem(
                repoID: two.id, ref: ExternalRef(kind: .issue, number: 3), dismissedAt: .now),
        ])

        model.selectedRepoID = nil
        #expect(model.dismissedFigure == "3 dismissed")
        model.selectedRepoID = one.id
        #expect(model.dismissedFigure == "2 dismissed")
        model.selectedRepoID = UUID()
        #expect(model.dismissedFigure == nil, "a repository with none says nothing, not zero")
    }

    // MARK: - 5. The wiring, not the arithmetic

    /// The figure is a reading of the **table**, not of the last import summary,
    /// which is what lets a restore decrement it immediately. That claim is
    /// entirely about the observation being subscribed, and the seam above
    /// cannot prove it — so this one stands the real thing up.
    @Test("The model observes the table, so a dismissal written behind it arrives")
    func theTableIsObserved() async throws {
        let one = repo()
        let store = try BoardStore.inMemory()
        try await store.saveRepo(one)
        let model = AppModel()
        model.testOnlySeedStore(store)
        model.observe(store: store)

        try await store.dismiss(ExternalRef(kind: .issue, number: 9), repoID: one.id)

        // Bounded, per this package's testing discipline: a wiring that was
        // never subscribed fails the suite in seconds rather than hanging
        // `swift test` and the SwiftPM build lock with it.
        try await withTimeout(.seconds(10)) {
            while await MainActor.run(body: { model.dismissedItems.isEmpty }) {
                await Task.yield()
            }
        }
        #expect(model.dismissedItems.first?.ref.number == 9)
        await model.shutdown()
    }
}
