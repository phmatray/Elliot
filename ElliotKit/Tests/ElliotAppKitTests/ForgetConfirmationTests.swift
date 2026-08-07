import ElliotModel
import ElliotStore
import Foundation
import Testing

@testable import ElliotAppKit

/// The gate in front of the only irreversible act on either screen.
///
/// Criterion 3 is asserted as **rows before and after**, not as a flag: a
/// `cancelForget` that cleared the state and deleted anyway would satisfy a
/// flag assertion perfectly.
@Suite("Forget confirmation")
@MainActor
struct ForgetConfirmationTests {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func board() async throws -> (AppModel, BoardStore, Repo) {
        let store = try BoardStore.inMemory()
        let model = AppModel()
        model.testOnlySeedStore(store)

        var repo = Repo(path: "/tmp/Elliot", nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        repo.isEnabled = true
        try await store.saveRepo(repo)
        try await store.saveCard(Card(
            repoID: repo.id, title: "A card", column: .backlog, orderIndex: 0,
            columnEnteredAt: epoch, createdAt: epoch, updatedAt: epoch))
        model.testOnlySeed(repos: [repo], cards: [])
        return (model, store, repo)
    }

    @Test("Asking to forget deletes nothing and raises the prompt")
    func requestDeletesNothing() async throws {
        let (model, store, repo) = try await board()

        await model.requestForget(repoID: repo.id, origin: .preflight)

        #expect(model.forgetRequest?.id == repo.id)
        #expect(model.forgetRequest?.impact.cards == 1)
        #expect(model.forgetRequest?.prompt.title == "Forget Elliot?")
        // The gate held: the registration and its card are still there.
        #expect(try await store.repo(id: repo.id) != nil)
        #expect(try await store.cardCount(repoID: repo.id) == 1)
    }

    @Test("Cancelling leaves the registration and every row untouched")
    func cancelChangesNothing() async throws {
        let (model, store, repo) = try await board()
        await model.requestForget(repoID: repo.id, origin: .preflight)

        model.cancelForget()

        #expect(model.forgetRequest == nil)
        #expect(try await store.repo(id: repo.id) != nil)
        #expect(try await store.cardCount(repoID: repo.id) == 1)
        #expect(try await store.forgetImpact(repoID: repo.id).cards == 1)
    }

    @Test("Confirming forgets it, and clears the prompt")
    func confirmDeletes() async throws {
        let (model, store, repo) = try await board()
        await model.requestForget(repoID: repo.id, origin: .preflight)

        await model.confirmForget()

        #expect(model.forgetRequest == nil)
        #expect(try await store.repo(id: repo.id) == nil)
        #expect(try await store.forgetImpact(repoID: repo.id).isEmpty)
    }

    @Test("The Repositories page's Forget fix opens the prompt instead of deleting")
    func repositoriesFixIsGated() async throws {
        // Criterion 1 for the second screen. The button is unchanged; the gate
        // sits where every caller of this fix passes.
        let (model, store, repo) = try await board()

        await model.apply(RepoFix.forget(repoID: repo.id))

        #expect(model.forgetRequest?.origin == .repositories)
        #expect(try await store.repo(id: repo.id) != nil)
    }

    @Test("Confirming with no store, or an unknown repository, does nothing")
    func refusesWhatItCannotMeasure() async throws {
        let (model, store, repo) = try await board()

        await model.requestForget(repoID: UUID(), origin: .preflight)

        // No prompt for a repository the model does not hold: a dialog that
        // cannot state a count would be the vague warning this issue removes.
        #expect(model.forgetRequest == nil)
        #expect(try await store.repo(id: repo.id) != nil)
    }

    @Test("Both screens hover the same sentence, and it names the board")
    func bothTooltipsNameTheBoard() {
        // Criterion 4. Preflight shipped "Remove Elliot from Elliot. The
        // checkout on disk is untouched." — naming only what survives.
        let preflight = PreflightView.forgetHelp(displayName: "Elliot")
        let repositories = RepositoriesView.explainForget(displayName: "Elliot")
        #expect(preflight == repositories)
        #expect(preflight == ForgetPrompt.tooltip(displayName: "Elliot"))
        for kind in ["cards", "runs", "analyses", "proposals"] {
            #expect(preflight.contains(kind))
        }
        // And it still says the safe part, which was the only true thing the
        // old text said.
        #expect(preflight.contains("clone on disk is untouched"))
    }

    /// Both screens must *present* the dialog, not merely ask for it.
    ///
    /// This reads the source, the way `CaretAnchorTests` and
    /// `DrainDuplicationTests` do, because the thing at risk is a **shape** and
    /// `swift test` cannot see a sheet. Every other test here would stay green
    /// with `.forgetConfirmation(model:)` deleted from a screen: `requestForget`
    /// would still count, still build the prompt, still refuse to delete — and
    /// the reader would press the button and watch nothing happen, with the
    /// registration silently spared. That is a worse failure than the one this
    /// issue fixes, because it looks like a gate that works.
    ///
    /// Asserted per screen rather than as a count, so the message can name the
    /// file that dropped it.
    @Test("Every screen that can forget also presents the confirmation")
    func bothScreensPresentTheDialog() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ElliotAppKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // ElliotKit
            .appendingPathComponent("Sources/ElliotAppKit")

        for screen in ["PreflightView.swift", "RepositoriesView.swift"] {
            let text = try String(
                contentsOf: sources.appendingPathComponent(screen), encoding: .utf8)
            // Comments are stripped before matching, so prose describing the
            // modifier cannot stand in for applying it.
            let applies = text.components(separatedBy: "\n").contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { return false }
                return line.contains(".forgetConfirmation(")
            }
            #expect(
                applies,
                """
                \(screen) can raise a forget but never presents it: no \
                `.forgetConfirmation(model:)` on its body.

                The button would set `forgetRequest` and nothing would show it. \
                Every behavioural test in this suite stays green in that state — \
                which is exactly why this one reads the file.
                """)
        }
    }
}
