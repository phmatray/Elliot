import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine

/// Records what the board asked for without spawning anything.
private actor RecordingLauncher: RunLaunching {
    private(set) var launched: [UUID] = []
    func launch(runID: UUID) async { launched.append(runID) }
    func cancel(runID: UUID) async {}
    func launchedRuns() -> [UUID] { launched }
}

private struct Fixture {
    var store: BoardStore
    var board: BoardService
    var launcher: RecordingLauncher
    var repo: Repo

    static func make(methodID: String? = nil) async throws -> Fixture {
        let store = try BoardStore.inMemory()
        let launcher = RecordingLauncher()
        let board = BoardService(store: store, launcher: launcher)
        var repo = Repo(
            path: "/tmp/repo-\(UUID().uuidString)",
            nameWithOwner: "phmatray/Elliot",
            displayName: "Elliot"
        )
        repo.methodID = methodID
        try await store.saveRepo(repo)
        return Fixture(store: store, board: board, launcher: launcher, repo: repo)
    }

    /// A card sitting in To Do with an issue on it — the one transition whose
    /// argument form is `.number` in every pack that has it.
    func filedCard() async throws -> Card {
        var card = try await board.createCard(repoID: repo.id, title: "Run log").card
        card.column = .todo
        card.issueNumber = 47
        try await store.saveCard(card)
        return card
    }
}

/// A built-in pack, other than the default, whose `implement-issue` step is a
/// *different* command **and takes a number**.
///
/// ⛔ Both halves matter. Without the command difference, a builder that ignored
/// its `method` argument entirely would still pass. Without
/// `arguments == .number`, the assertion `"\(expected) 47"` is a claim about a
/// tail shape this predicate never selected for — a pack whose step took
/// `.ideaThenLabels` would fail this test for a reason unrelated to the wiring.
/// A built-in pack, other than the default, that declares a *different* command
/// for `kind`.
///
/// ⚠️ **The transition matters, and the brief picked one where wave 1's
/// catalogue cannot answer.** Its version of this predicate asked for a
/// contrasting `.implementIssue` step, and measured, there is none: amendment A3
/// gives GSD only `.createIssue` (`/gsd-plan-phase` takes a *phase* number and
/// Elliot's card carries an *issue* number, so binding it would act on the wrong
/// object), BMAD ships no steps at all, and Spec Kit declares only its first.
/// The test therefore recorded its "no contrasting pack" issue and left the
/// suite permanently red — a loud gap, but one that destroys the signal it was
/// meant to raise.
///
/// `.createIssue` is where the catalogue genuinely contrasts today, so that is
/// where the claim is measured. The `nil` branch stays: it is what will say so
/// out loud if a future catalogue stops contrasting anywhere.
private func contrastingPack(against base: MethodPack, at kind: SkillKind) -> MethodPack? {
    MethodCatalog.builtIn.first { pack in
        guard pack.id != base.id, let step = pack.steps[kind] else { return false }
        return step.command != base.steps[kind]?.command
    }
}

@Suite("The repository's method decides the command")
struct MethodPromptTests {

    /// Wave 1's claim, measured one layer above `GoldenPromptTests`: a
    /// repository that never chose a method runs exactly what it ran before.
    @Test("A repository with no method chosen produces the shipped prompt")
    func unsetRepositoryIsUnchanged() async throws {
        let f = try await Fixture.make()
        let card = try await f.filedCard()

        let result = try await f.board.move(cardID: card.id, to: .inProgress, origin: .userDrag)
        guard case .moved(let runID?) = result else {
            Issue.record("expected a run, got \(result)")
            return
        }
        let run = try #require(try await f.store.run(id: runID))
        #expect(run.prompt == "/ai-migration-kit:implement-issue 47")
    }

    /// The point of the wave: the row decides. Asserted against the pack's own
    /// declared command rather than a literal, so this test measures the wiring
    /// and not the catalogue's wording.
    @Test("The repository's pack supplies the command")
    func chosenPackSuppliesTheCommand() async throws {
        guard case .unset(let base) = MethodCatalog.resolve(nil) else {
            Issue.record("MethodCatalog.resolve(nil) did not answer .unset with a pack")
            return
        }
        guard let other = contrastingPack(against: base, at: .createIssue) else {
            // ⚠️ Wave 1's catalogue may genuinely contain no such pack — GSD and
            // Spec Kit both declare only `.createIssue`. Say so rather than pass
            // in silence, so the gap is visible the day it can be closed.
            // Hoisted into a `let`: `Issue.record` takes a `Comment`, which is
            // `ExpressibleByStringLiteral`, so a `+` between two literals in the
            // argument position resolves against `Sequence` and fails to compile.
            // Hoisted into a `let`: `Issue.record` takes a `Comment`, which is
            // `ExpressibleByStringLiteral`, so a `+` between two literals in the
            // argument position resolves against `Sequence` and fails to compile.
            let gap = "no built-in pack declares a different create-issue command; "
                + "the repository-decides claim is untested at every transition"
            Issue.record(Comment(rawValue: gap))
            return
        }
        let expected = try #require(other.steps[.createIssue]).command

        let f = try await Fixture.make(methodID: other.id)
        let card = try await f.board.createCard(repoID: f.repo.id, title: "Add a dark mode toggle")
            .card

        let result = try await f.board.move(cardID: card.id, to: .todo, origin: .userDrag)
        guard case .moved(let runID?) = result else {
            Issue.record("expected a run, got \(result)")
            return
        }
        let run = try #require(try await f.store.run(id: runID))
        // The pack's own declared command, not a literal — this measures the
        // wiring rather than the catalogue's current wording.
        #expect(run.prompt.hasPrefix("\(expected) "))
        #expect(run.prompt.contains("Add a dark mode toggle"))
        // ⛔ The half that would still pass if `makeRun` ignored `repo.method`
        // and resolved the default pack instead.
        #expect(!run.prompt.contains("ai-migration-kit"))
    }

    /// ⛔ The refusal that matters. A repository set to a method this build does
    /// not know has no commands, and running another method's inside it — at
    /// `bypassPermissions`, in a real checkout — is the silent substitution the
    /// three-valued `MethodResolution` exists to refuse. The card must not move
    /// either: `makeRun` runs before the move's transaction, so a throw leaves
    /// the board exactly as it was.
    @Test("An unknown method refuses the move and names the id")
    func unknownMethodRefuses() async throws {
        let f = try await Fixture.make(methodID: "no-such-method")
        let card = try await f.filedCard()

        do {
            let result = try await f.board.move(cardID: card.id, to: .inProgress, origin: .userDrag)
            Issue.record("the move was allowed with an unknown method: \(result)")
        } catch let error as BoardError {
            #expect(
                error.errorDescription?.contains("no-such-method") == true,
                "the refusal did not name the method: \(error.errorDescription ?? "nil")"
            )
        } catch {
            Issue.record("expected a BoardError, got \(error)")
        }

        #expect(try await f.store.card(id: card.id)?.column == .todo)
        #expect(await f.launcher.launchedRuns().isEmpty)
    }

    /// A pack may declare no step for a kind — the catalogue ships one that
    /// declares none at all. The builder stays total and answers with the bare
    /// skill name; the *board* is what must refuse, because it is the thing that
    /// can decline to move a card.
    @Test("A pack with no step for the transition refuses rather than borrowing one")
    func steplessPackRefuses() async throws {
        guard let stepless = MethodCatalog.builtIn.first(where: { $0.steps[.implementIssue] == nil })
        else {
            // ⛔ Not `#expect(builtIn.allSatisfy { … != nil })`, which is true by
            // construction here and can never fail — the previous draft's
            // fallback said it was refusing to pass in silence while doing
            // exactly that, leaving `BoardError.methodHasNoStep` shipped with
            // zero coverage.
            let gap = "no built-in pack is stepless at .implementIssue; "
                + "BoardError.methodHasNoStep is unreachable and untested"
            Issue.record(Comment(rawValue: gap))
            return
        }

        let f = try await Fixture.make(methodID: stepless.id)
        let card = try await f.filedCard()

        do {
            let result = try await f.board.move(cardID: card.id, to: .inProgress, origin: .userDrag)
            Issue.record("the move was allowed with no step to run: \(result)")
        } catch let error as BoardError {
            #expect(error.errorDescription?.contains(stepless.displayName) == true)
        } catch {
            Issue.record("expected a BoardError, got \(error)")
        }

        #expect(try await f.store.card(id: card.id)?.column == .todo)
        #expect(await f.launcher.launchedRuns().isEmpty)
    }
}
