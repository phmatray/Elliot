import ElliotEngine
import ElliotModel
import ElliotStore
import Foundation
import Testing

@testable import ElliotAppKit

/// Records what the board asked for without spawning anything.
private actor SilentLauncher: RunLaunching {
    func launch(runID: UUID) async {}
    func cancel(runID: UUID) async {}
}

/// The New story face: where it files, and what it does with what you typed.
///
/// Two defects, one screen. A refused *Add to backlog* closed the console and
/// destroyed a full user story while looking exactly like a success (#313); and
/// the face named a repository the reader had no control over, resolved from
/// `selectedRepoID ?? repos.first?.id` — alphabetical luck presented as a
/// decision (#314). They meet in the same place: the story only survives a
/// refusal if it is not in the view, and it is only worth surviving if it is
/// pointed somewhere the reader chose.
@MainActor
@Suite("New story face")
struct NewStoryFaceTests {

    // MARK: - Fixtures

    private static func repo(_ name: String) -> Repo {
        Repo(
            path: "/tmp/\(name)", nameWithOwner: "phmatray/\(name)",
            defaultBranch: "main", displayName: name)
    }

    private static func model(_ repos: [Repo]) -> AppModel {
        let model = AppModel()
        model.testOnlySeed(repos: repos, cards: [])
        return model
    }

    /// A story that `CardDraft.isValid` accepts, so a refusal in a test can only
    /// have come from the thing the test is about.
    private static func filledDraft(title: String = "Keep the story") -> CardDraft {
        CardDraft(
            title: title, isStory: true, role: "someone writing a story",
            want: "the text to survive a refusal",
            benefit: "I am not punished for a condition I did not cause",
            criteria: ["the draft is still there", "the reason is on screen"],
            labels: ["enhancement"])
    }

    /// A model with a **real** board behind it, so a create can genuinely fail.
    ///
    /// `testOnlySeed` deliberately leaves `board` nil, which proves only the
    /// guard at the top of `addStoryToBacklog`. The interesting refusal is the
    /// one that comes back *from* `BoardService`, and `registered` is what
    /// arranges it: with `false` the repository is on the board and **not** in
    /// the store, which is precisely the state a repository forgotten from the
    /// Repositories face leaves behind — `createCard` throws
    /// `BoardError.repoNotFound` and the old code discarded the story on the way
    /// out.
    private static func withBoard(
        registered: Bool = true,
        _ body: (AppModel, Repo, BoardStore) async throws -> Void
    ) async throws {
        let store = try BoardStore.inMemory()
        let board = BoardService(store: store, launcher: SilentLauncher())
        let repo = Self.repo("Elliot")
        if registered { try await store.saveRepo(repo) }

        let model = Self.model([repo])
        model.testOnlySeedStore(store)
        model.testOnlyAttachBoard(board)
        try await body(model, repo, store)
    }

    // MARK: - Where the story is filed

    /// ⛔ The property the whole face rests on: there is exactly one
    /// repository-less state, and it is one the reader can see the reason for.
    @Test("The face has no repository if and only if the board has none")
    func theTargetIsNilOnlyOnAnEmptyBoard() {
        #expect(AppModel().newCardRepo == nil)

        let model = Self.model([Self.repo("Alpha")])
        #expect(model.newCardRepo != nil)
    }

    @Test("With no choice made, the face follows the board's picker")
    func itFollowsTheBoardPicker() {
        let (alpha, beta) = (Self.repo("Alpha"), Self.repo("Beta"))
        let model = Self.model([alpha, beta])

        model.selectedRepoID = beta.id
        #expect(model.newCardRepo?.id == beta.id)
    }

    /// "All repositories" is not a place a card can land, so the face takes the
    /// first — the behaviour #314 calls alphabetical luck. It stays, and stops
    /// being luck because the picker beside it can now correct it.
    @Test("On All repositories it takes the first, and the picker can correct it")
    func itFallsBackToTheFirst() {
        let (alpha, beta) = (Self.repo("Alpha"), Self.repo("Beta"))
        let model = Self.model([alpha, beta])
        model.selectedRepoID = nil

        #expect(model.newCardRepo?.id == alpha.id)

        model.newCardRepoID = beta.id
        #expect(model.newCardRepo?.id == beta.id)
    }

    @Test("The reader's choice outranks the board's picker")
    func theChoiceWins() {
        let (alpha, beta) = (Self.repo("Alpha"), Self.repo("Beta"))
        let model = Self.model([alpha, beta])
        model.selectedRepoID = beta.id
        model.newCardRepoID = alpha.id

        #expect(model.newCardRepo?.id == alpha.id)
    }

    /// ⛔ The stale id. A repository can be forgotten from the Repositories face
    /// while this one is open; resolving through `repos` rather than trusting the
    /// stored id is what stops a dead UUID reaching `createCard`.
    @Test("A chosen repository that has since been forgotten falls back, never dangles")
    func aForgottenChoiceFallsBack() {
        let (alpha, beta) = (Self.repo("Alpha"), Self.repo("Beta"))
        let model = Self.model([alpha, beta])
        model.selectedRepoID = beta.id
        model.newCardRepoID = UUID()  // registered, then forgotten

        #expect(model.newCardRepo?.id == beta.id)
    }

    // MARK: - Surviving a hide

    /// ⛔ The regression #314 is half about. Folding the console destroys the
    /// face; the story must not be in it.
    @Test("A typed story survives the console being folded away and re-opened")
    func typingSurvivesAFold() {
        let model = Self.model([Self.repo("Alpha")])
        model.showConsoleFace(.newStory)
        model.newCardDraft = Self.filledDraft(title: "Half written")
        model.newCardDraft.criteria = ["a", "b", "c", "d", "e", "f", "g", "h"]

        // What hiding actually does — the ✕, Escape and every door reach this.
        model.closeConsole()
        model.showConsoleFace(.newStory)

        #expect(model.newCardDraft.title == "Half written")
        #expect(model.newCardDraft.criteria.count == 8)
        #expect(model.newCardDraft.labels == ["enhancement"])
    }

    @Test("The chosen repository survives a fold too")
    func theChoiceSurvivesAFold() {
        let (alpha, beta) = (Self.repo("Alpha"), Self.repo("Beta"))
        let model = Self.model([alpha, beta])
        model.showConsoleFace(.newStory)
        model.newCardRepoID = beta.id

        model.closeConsole()
        model.showConsoleFace(.newStory)

        #expect(model.newCardRepo?.id == beta.id)
    }

    /// ⚠️ Re-opening the face must not re-guess the repository. Both entry
    /// points used to assign `selectedRepoID ?? repos.first?.id` here, which
    /// would silently overwrite a choice the reader had made and folded away.
    @Test("Re-opening the face does not overwrite the choice with the board's")
    func reopeningKeepsTheChoice() {
        let (alpha, beta) = (Self.repo("Alpha"), Self.repo("Beta"))
        let model = Self.model([alpha, beta])
        model.selectedRepoID = alpha.id
        model.newCardRepoID = beta.id

        model.closeConsole()
        model.showConsoleFace(.newStory)

        #expect(model.newCardRepo?.id == beta.id)
    }

    // MARK: - A refusal keeps the story

    /// ⛔ The regression #313 is about, at the guard that used to be
    /// `guard let board else { return }` — a refusal that did nothing at all and
    /// was then followed by `closeConsole()` on the caller's next line.
    @Test("A refusal keeps the story, keeps the face open, and says why")
    func aRefusalKeepsEverything() async {
        let model = Self.model([Self.repo("Alpha")])
        model.showConsoleFace(.newStory)
        model.newCardDraft = Self.filledDraft()

        await model.addStoryToBacklog()

        #expect(model.newStoryRefusal != nil, "nothing was filed and nothing said so")
        #expect(model.newCardDraft.title == "Keep the story")
        #expect(model.newCardDraft.criteria.count == 2)
        #expect(model.console.face == .newStory, "the face closed on a refusal")
    }

    /// The refusal that comes back from `BoardService` rather than from a guard:
    /// the repository was forgotten between opening the face and pressing Add.
    @Test("A create the board refuses keeps the story and names the reason")
    func aBoardRefusalKeepsTheStory() async throws {
        try await Self.withBoard(registered: false) { model, _, store in
            model.showConsoleFace(.newStory)
            model.newCardDraft = Self.filledDraft(title: "Filed nowhere")

            await model.addStoryToBacklog()

            let refusal = try #require(model.newStoryRefusal)
            #expect(refusal.contains("No repository with id"))
            #expect(model.newCardDraft.title == "Filed nowhere")
            #expect(model.console.face == .newStory)
            let filed = try await store.cards()
            #expect(filed.isEmpty)
        }
    }

    @Test("An incomplete story is refused by name rather than filed half-written")
    func anIncompleteStoryIsRefused() async throws {
        try await Self.withBoard { model, _, store in
            model.showConsoleFace(.newStory)
            model.newCardDraft = CardDraft(title: "  ")

            await model.addStoryToBacklog()

            #expect(model.newStoryRefusal?.contains("board label") == true)
            let filed = try await store.cards()
            #expect(filed.isEmpty)
            #expect(model.console.face == .newStory)
        }
    }

    @Test("With no repository at all the refusal says so")
    func anEmptyBoardRefusesWithAReason() async {
        let model = AppModel()
        model.showConsoleFace(.newStory)
        model.newCardDraft = Self.filledDraft()

        await model.addStoryToBacklog()

        #expect(model.newStoryRefusal?.contains("No repository is registered") == true)
        #expect(model.newCardDraft.title == "Keep the story")
    }

    /// ⚠️ The sentence belongs to the repository it was thrown for. The face now
    /// carries its own picker, so the subject can change while the refusal is on
    /// screen — and a refusal about Alpha rendered beside a live Add button for
    /// Beta is a sentence under a subject it does not belong to.
    @Test("A refusal is scoped to the repository it was refused for")
    func theRefusalIsScopedToItsRepository() async {
        let (alpha, beta) = (Self.repo("Alpha"), Self.repo("Beta"))
        let model = Self.model([alpha, beta])
        model.newCardRepoID = alpha.id
        model.newCardDraft = Self.filledDraft()

        await model.addStoryToBacklog()
        #expect(model.newStoryRefusal != nil)

        model.newCardRepoID = beta.id
        #expect(model.newStoryRefusal == nil, "Alpha's refusal is showing under Beta")

        model.newCardRepoID = alpha.id
        #expect(model.newStoryRefusal != nil, "nothing was attempted for Alpha in between")
    }

    /// A second attempt must not read as the first one's failure.
    @Test("A later attempt clears the previous refusal before it decides")
    func theRefusalIsClearedOnEachAttempt() async throws {
        try await Self.withBoard { model, _, _ in
            model.showConsoleFace(.newStory)
            model.newCardDraft = CardDraft(title: "")
            await model.addStoryToBacklog()
            #expect(model.newStoryRefusal != nil)

            model.newCardDraft = Self.filledDraft()
            await model.addStoryToBacklog()
            #expect(model.newStoryRefusal == nil)
        }
    }

    // MARK: - Success

    @Test("A filed story reaches the backlog whole, and empties the face")
    func aFiledStoryClearsTheFace() async throws {
        try await Self.withBoard { model, repo, store in
            model.showConsoleFace(.newStory)
            model.newCardRepoID = repo.id
            model.newCardDraft = Self.filledDraft(title: "Filed for real")

            await model.addStoryToBacklog()

            let cards = try await store.cards()
            #expect(cards.count == 1)
            let card = try #require(cards.first)
            #expect(card.title == "Filed for real")
            #expect(card.column == .backlog)
            #expect(card.repoID == repo.id)
            #expect(card.labels == ["enhancement"])
            #expect(card.story?.acceptanceCriteria.count == 2)

            // The face is empty and folded: the story is filed, so there is no
            // story and no choice.
            #expect(model.newCardDraft.title.isEmpty)
            #expect(model.newCardDraft.criteria == [""])
            #expect(model.newCardDraft.labels.isEmpty)
            #expect(model.newCardRepoID == nil)
            #expect(model.newStoryRefusal == nil)
            #expect(model.console.face == nil, "a filed story left the face open")
        }
    }

    /// The title is stored as `CardDraft.trimmedTitle`, which is the same value
    /// `isValid` gated on — the gate and the write are one expression (#202).
    @Test("The stored board label is the trimmed one the gate judged")
    func theStoredTitleIsTrimmed() async throws {
        try await Self.withBoard { model, _, store in
            model.newCardDraft = Self.filledDraft(title: "  Padded  \n")

            await model.addStoryToBacklog()

            let filed = try await store.cards()
            #expect(filed.first?.title == "Padded")
        }
    }

    // MARK: - Deleting

    /// The other silent write #313 names: from the board's context menu and the
    /// Archive's, a delete that did nothing looked exactly like one that worked.
    @Test("A delete that cannot happen says so")
    func aRefusedDeleteIsReported() async {
        let model = AppModel()
        let before = model.status

        await model.deleteCard(id: UUID())

        #expect(model.status != before)
        #expect(model.status.contains("not deleted"))
    }
}

/// The state that may stay in the New story face, and why.
///
/// ⚠️ A source gate, for the reason `AnalysisPanelStateTests` gives one screen
/// over: a behavioural test cannot see a `@State` nobody thought to move. The
/// test that "proved" hiding the analysis panel was lossless only looked at the
/// half of the state that already lived on the model, and this face is the same
/// mechanism — `ConsoleState.close` drops the face and the subtree with it.
///
/// **Why an allow-list rather than a flat ban.** The honest criterion is
/// *re-derivability*: a disclosure toggle reopens onto the same rows and costs
/// nothing, a half-written story exists nowhere else. No matcher can tell those
/// apart, so the gate's job is not to decide — it is to make the judgement happen
/// in review, once, with a reason written down beside the name. The list is empty
/// today because this face holds nothing of the first kind; an entry added to it
/// is a claim someone has to defend.
@Suite("New story holds no lossy state")
struct NewStoryStateTests {

    /// The face's whole subtree: its own file and the field editor it embeds.
    ///
    /// `CardFieldsEditor` is included because it is destroyed by the same fold —
    /// and it was covered by neither this gate nor the analysis one, although it
    /// renders inside both. It is where the story fields actually are.
    private static let files = ["NewStoryView.swift", "CardFieldsEditor.swift"]

    private static let allowed: Set<String> = []

    @Test("Nothing the reader types or chooses is @State in the face")
    func noLossyStateInTheFace() throws {
        for file in Self.files {
            let declared = Set(try HiddenFaceState.declared(in: file))
            let unexpected = declared.subtracting(Self.allowed)
            #expect(
                unexpected.isEmpty,
                Comment(
                    rawValue:
                        "\(unexpected.sorted().joined(separator: ", ")) is @State in \(file). "
                        + "Folding the console destroys this whole subtree, so a story typed into "
                        + "it is gone with no way to tell a lost draft from one never written. "
                        + "Move it to AppModel, or add it to `allowed` with a reason it is "
                        + "re-derivable."))
        }
    }

    /// A negative needs its positive witness: a renamed file, or a face that
    /// stopped binding to the model, would make the claim above vacuously true.
    @Test("The gate is reading the real face")
    func theGateReadsTheFace() throws {
        let face = try HiddenFaceState.code(of: "NewStoryView.swift")
        #expect(face.contains("struct NewStoryView: View"))
        #expect(
            face.contains("$model.newCardDraft"),
            """
            the face is no longer bound to AppModel.newCardDraft — has the story moved back \
            into the view?
            """)

        let editor = try HiddenFaceState.code(of: "CardFieldsEditor.swift")
        #expect(editor.contains("@Binding var draft: CardDraft"))
    }

    /// The allow-list must not outlive what it allows.
    @Test("The allow-list names nothing that has already gone")
    func theAllowListIsNotStale() throws {
        var declared: Set<String> = []
        for file in Self.files { declared.formUnion(try HiddenFaceState.declared(in: file)) }
        #expect(Self.allowed.subtracting(declared).isEmpty)
    }

    // MARK: - Where the repository picker lives

    /// ⛔ **The picker belongs to the New story header, never to
    /// `CardFieldsEditor`.**
    ///
    /// That editor is shared by this face, the detail panel's edit mode and the
    /// proposal editor. A repository control inside it would grow the detail
    /// panel a way to change a card's repository — a second write path to a
    /// card's identity, which `BoardView.groupHeader`'s no-drop-target comment
    /// already refuses — and the proposal editor a control whose value
    /// `CardDraft.applied(to:)` has nowhere to put, which is the discarding
    /// editor `Kind` exists to prevent.
    ///
    /// A source gate because `swift test` cannot see a view: moving the picker
    /// one file in leaves every behavioural test in this suite green.
    @Test("The repository picker is in the face, not in the shared field editor")
    func thePickerIsNotInTheSharedEditor() throws {
        let face = try HiddenFaceState.code(of: "NewStoryView.swift")
        #expect(
            face.contains("model.newCardRepoID = $0"),
            "the New story header no longer writes the chosen repository (#314)")

        let editor = try HiddenFaceState.code(of: "CardFieldsEditor.swift")
        for needle in ["newCardRepoID", "newCardRepo", "model.repos"] {
            #expect(
                !editor.contains(needle),
                Comment(
                    rawValue:
                        "CardFieldsEditor mentions \(needle). It is shared with the detail panel's "
                        + "edit mode and the proposal editor, so a repository control here is a "
                        + "second write path to a card's identity (#314)."))
        }
    }

    /// ⛔ **The picker offers repositories and nothing else.**
    ///
    /// The board's toolbar picker leads with `Text("All repositories").tag(UUID?.none)`,
    /// where the tag means *do not filter*; copied here it would mean *file
    /// nowhere*, and selecting it would disable Add with nothing on screen saying
    /// why. `AppModel.newCardRepo` cannot produce that state — it falls back to
    /// `repos.first` — so the only way back into it is a row in this picker.
    ///
    /// ⚠️ **Found by break-testing, not by design.** Adding that row back left
    /// the whole suite green (2 159 tests): the arithmetic underneath is pinned
    /// and the row is view text, which `swift test` cannot see.
    @Test("The picker offers no selection that cannot be filed")
    func thePickerHasNoAllRepositoriesRow() throws {
        let face = try HiddenFaceState.code(of: "NewStoryView.swift")

        // Positive witness: the picker is still built from the repository list,
        // so the negatives below are about what it offers rather than about a
        // control that has gone.
        #expect(face.contains("ForEach(model.repos)"), "the repository picker has gone")

        for needle in ["UUID?.none", "All repositories"] {
            #expect(
                !face.contains(needle),
                Comment(
                    rawValue:
                        "the New story picker offers \"\(needle)\". On the board's toolbar that tag "
                        + "means \"do not filter\"; here it would mean \"file nowhere\", and a card "
                        + "must land somewhere (#314)."))
        }
    }

    // MARK: - The refusal reaches the reader

    /// ⛔ **The model recording a refusal is only half of #313; the face has to
    /// draw it.**
    ///
    /// ⚠️ **This gate exists because its absence was measured.** Deleting the
    /// refusal block from `NewStoryView` left all 2 159 tests green — the story
    /// survived, the face stayed open, and the reader was told nothing, which is
    /// the original defect with one of its two halves repaired. Every behavioural
    /// test in this file reads `AppModel`, and `swift test` cannot see a view.
    ///
    /// It checks the tier as well as the text: `Palette.refused` is this app's
    /// "a move was refused, or a run failed", and a refusal drawn in the prose
    /// tier reads as a caption on a screen that looks like it worked.
    @Test("The face draws the refusal, in the refusal tier")
    func theFaceRendersTheRefusal() throws {
        let face = try HiddenFaceState.code(of: "NewStoryView.swift")

        #expect(
            face.contains("model.newStoryRefusal"),
            """
            NewStoryView never reads AppModel.newStoryRefusal. The model records why nothing was \
            filed and the screen says nothing, which is #313 with the story kept and the reason \
            still lost — and the status bar cannot stand in for it: one truncated line at the far \
            corner of the window, owned by whoever narrated last.
            """)
        #expect(
            face.contains("Palette.refused"),
            "the refusal is not drawn in the refusal tier, so a refused Add reads as a caption")
    }
}
