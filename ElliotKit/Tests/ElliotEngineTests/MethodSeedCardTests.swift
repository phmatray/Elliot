import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine

private actor SilentLauncher: RunLaunching {
    func launch(runID: UUID) async {}
    func cancel(runID: UUID) async {}
}

/// The seeded card, end to end: the fix a gap carries, pressed, twice, in two
/// repositories.
///
/// ⛔ This is the only place the **board-wide** uniqueness of
/// `card_on_idempotencyKey` is exercised. `Migrations.swift:34-42` makes the
/// index unique on the key alone and says why; `BoardStore.card(idempotencyKey:)`
/// filters on the key alone; `BoardService.createCard`'s own doc says *"A key
/// that names a card in another repository still returns that card."* So a
/// repo-free key — which is what the spec wrote — makes the **second**
/// repository to choose a method find the first one's card and be seeded
/// nothing, while `CheckFixOutcome` reports `succeeded: true` and
/// *"Added a card to Backlog."* That is a success that did not happen, and it is
/// invisible to every assertion about the key *string*.
@Suite("A project requirement seeds one card per repository")
struct MethodSeedCardTests {

    private func board(_ store: BoardStore) -> BoardService {
        BoardService(store: store, launcher: SilentLauncher())
    }

    private func service() -> PreflightService {
        PreflightService(
            environment: LoginShellEnvironment(variables: [:], capturedVia: "test"),
            config: ToolConfig(
                ghPath: "/usr/bin/false", gitPath: "/usr/bin/git",
                environment: ["PATH": "/usr/bin:/bin"]
            )
        )
    }

    private func pack() throws -> MethodPack {
        try #require(MethodCatalog.builtIn.first { !$0.projectRequirements.isEmpty })
    }

    /// The gap's own fix, taken from `projectChecks` rather than rebuilt here —
    /// a test that constructed its own `CheckFix` would be testing itself.
    private func seedFix(_ pack: MethodPack, _ repo: Repo) throws -> CheckFix {
        let satisfied: [MethodPack.Evidence: Bool] = [:]   // nothing on disk
        let checks = PreflightService.projectChecks(repo: repo, pack: pack, satisfied: satisfied)
        return try #require(checks.first?.fixes.first, "a gap must offer a card")
    }

    private func repository(_ name: String) -> Repo {
        Repo(path: "/tmp/\(name)", nameWithOwner: "phmatray/\(name)", displayName: name)
    }

    @Test("Pressing the fix files one card, and pressing it again files no second one")
    func seedsOnceForOneRepository() async throws {
        let store = try BoardStore.inMemory()
        let board = board(store)
        let pack = try pack()
        var repo = repository("alpha")
        repo.methodID = pack.id
        try await store.saveRepo(repo)

        let fix = try seedFix(pack, repo)
        let first = await service().apply(fix, repo: repo, board: board)
        #expect(first.succeeded)

        let afterFirst = try await store.cards(repoID: repo.id, column: .backlog)
        #expect(afterFirst.count == 1)
        #expect(afterFirst.first?.idempotencyKey == fix.id)
        // Backlog, where nothing runs: a fix that filed into `.todo` would start
        // an unattended agent the instant the button was pressed.
        #expect(afterFirst.first?.column == .backlog)

        // The button does not disappear after a press — the artefact is still
        // missing, so the same row is rebuilt with the same fix, and nothing
        // disables it during the await.
        let second = await service().apply(fix, repo: repo, board: board)
        #expect(second.succeeded)
        #expect(try await store.cards(repoID: repo.id, column: .backlog).count == 1)
    }

    /// ⛔ The test the key correction exists for. Delete the repository from
    /// `MethodPack.idempotencyKey(for:in:)` and this one goes red while every
    /// other assertion in the plan stays green.
    @Test("Two repositories choosing the same method each get their own card")
    func twoRepositoriesEachGetTheirOwnCard() async throws {
        let store = try BoardStore.inMemory()
        let board = board(store)
        let pack = try pack()

        var alpha = repository("alpha"); alpha.methodID = pack.id
        var beta = repository("beta"); beta.methodID = pack.id
        try await store.saveRepo(alpha)
        try await store.saveRepo(beta)

        let alphaFix = try seedFix(pack, alpha)
        let betaFix = try seedFix(pack, beta)
        #expect(alphaFix.id != betaFix.id, "the two repositories share one key")

        #expect(await service().apply(alphaFix, repo: alpha, board: board).succeeded)
        #expect(await service().apply(betaFix, repo: beta, board: board).succeeded)

        let inAlpha = try await store.cards(repoID: alpha.id, column: .backlog)
        let inBeta = try await store.cards(repoID: beta.id, column: .backlog)
        #expect(inAlpha.count == 1, "alpha was seeded \(inAlpha.count) cards")
        #expect(inBeta.count == 1, "beta was seeded \(inBeta.count) cards — the key lost the repo")
        #expect(inAlpha.first?.id != inBeta.first?.id)
    }

    @Test("The seeded card is a complete story, so it can be dragged the moment it lands")
    func theSeededCardIsDraggable() async throws {
        // `evaluateMove` refuses an incomplete story with `MoveBlock.incompleteStory`.
        // A card Preflight created and the board will not move is worse than no
        // card: the reader has to discover it by trying.
        let store = try BoardStore.inMemory()
        let board = board(store)
        let pack = try pack()
        var repo = repository("gamma"); repo.methodID = pack.id
        try await store.saveRepo(repo)

        _ = await service().apply(try seedFix(pack, repo), repo: repo, board: board)
        let card = try #require(try await store.cards(repoID: repo.id, column: .backlog).first)
        #expect(card.story?.isComplete == true)
    }
}
