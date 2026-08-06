import Foundation
import Testing

@testable import ElliotModel

/// Which screen the board draws, and — the point of #118 — that the two lines
/// on it cannot contradict each other.
@Suite("Board phase")
struct BoardPhaseTests {

    // MARK: - Criterion 2, stated as something that cannot be written

    /// The bug, as an exhaustive claim rather than one example.
    ///
    /// "Still starting" over "Ready." was two surfaces reading two facts with
    /// nothing owning the pair. `.starting` is the only phase whose detail is
    /// the shared `status` line, so it is the only one that can inherit a
    /// readiness claim — and it is unreachable once `isReady` is true. Swept
    /// over every combination of the four inputs, because a single example
    /// would pass against a fix that only handled the case I happened to pick.
    @Test("Once startup has finished, the board never says it is still starting")
    func startingIsUnreachableAfterReady() {
        for hasLoaded in [true, false] {
            for repoCount in [0, 1, 7] {
                for failure in [nil, "boom"] as [String?] {
                    let phase = BoardPhase.of(
                        hasLoadedRepos: hasLoaded, isReady: true,
                        repoCount: repoCount, failure: failure)
                    #expect(phase != .starting, "loaded=\(hasLoaded) repos=\(repoCount)")
                    // And the concrete pairing that was on screen: whatever it
                    // draws, it is never the starting title over the ready line.
                    #expect(!(phase.title == "Still starting" && phase.detail(status: "Ready.") == "Ready."))
                }
            }
        }
    }

    /// The other half, so the test above is not passing because nothing is ever
    /// `.starting`: while startup is genuinely running, it is.
    @Test("While startup is running the board says so, and shows its progress line")
    func startingIsReachableBeforeReady() {
        let phase = BoardPhase.of(
            hasLoadedRepos: false, isReady: false, repoCount: 0, failure: nil)
        #expect(phase == .starting)
        #expect(phase.title == "Still starting")
        #expect(phase.detail(status: "Capturing your login shell…") == "Capturing your login shell…")
    }

    // MARK: - The state the bug actually left the app in

    /// Startup finished and the list never came. Reported **without** an error
    /// having been caught, because an observation that throws is only one route
    /// here — one that simply never delivers is another, and it leaves nothing
    /// to catch anywhere.
    @Test("Startup finished with no repository list is a failure, not a wait")
    func readyWithoutReposIsUnreadable() {
        let phase = BoardPhase.of(
            hasLoadedRepos: false, isReady: true, repoCount: 0, failure: nil)

        #expect(phase == .unreadable(reason: BoardPhase.neverArrived))
        #expect(phase.isFailure)
        #expect(phase.title == "Could not read your repositories")
        #expect(phase.detail(status: "Ready.") == BoardPhase.neverArrived)
        // The reason must not be the status line — that is the sentence that
        // said "Ready." while the board hung.
        #expect(phase.detail(status: "Ready.") != "Ready.")
    }

    @Test("A recorded error is preferred over the generic reason, and is shown verbatim")
    func recordedErrorIsShown() {
        let phase = BoardPhase.of(
            hasLoadedRepos: false, isReady: true, repoCount: 0,
            failure: "could not decode Repo.id")

        #expect(phase == .unreadable(reason: "could not decode Repo.id"))
        #expect(phase.detail(status: "Ready.") == "could not decode Repo.id")
    }

    // MARK: - Criterion 4: one bad row must not blank the board

    /// A failure that lands *after* a good delivery keeps the repositories
    /// already on screen. Blanking them would trade one false "fine" for a
    /// different one — an empty board that means "I could not ask".
    @Test("A failure after a successful delivery still draws the board")
    func laterFailureKeepsTheRepositoriesItHas() {
        #expect(
            BoardPhase.of(
                hasLoadedRepos: true, isReady: true, repoCount: 3,
                failure: "one row could not be decoded") == .ready)
    }

    // MARK: - The empty store, which is not a failure

    /// `.empty` and `.unreadable` must stay different screens: "there is
    /// nothing to show" and "I could not look" are different answers, and
    /// conflating them is what #42 was.
    @Test("A readable store holding nothing is empty, never unreadable")
    func emptyIsNotAFailure() {
        let phase = BoardPhase.of(
            hasLoadedRepos: true, isReady: true, repoCount: 0, failure: nil)

        #expect(phase == .empty)
        #expect(!phase.isFailure)
        #expect(phase.title == "No repository yet")
        // No detail: the empty state carries its own copy and an action button.
        #expect(phase.detail(status: "Ready.") == nil)
    }

    // MARK: - Criterion 4: partial success, said out loud

    /// Some rows read and some did not: the board draws what it has. Blanking it
    /// would trade one false "fine" for a different one.
    @Test("Rows that did read still draw the board")
    func partialReadStillDrawsTheBoard() {
        #expect(
            BoardPhase.of(
                hasLoadedRepos: true, isReady: true, repoCount: 3,
                failure: nil, unreadableCount: 1) == .ready)
    }

    /// …and the skip is never silent, which is the clause the whole of Task 3
    /// turns on: a skipped row nobody mentions is the original defect with a
    /// smaller blast radius.
    @Test("A skipped row always produces a sentence, and a clean read never does")
    func skippedRowsAreAlwaysSaid() {
        #expect(BoardPhase.skippedNote(0) == nil)
        #expect(BoardPhase.skippedNote(-1) == nil)
        for count in 1...4 {
            let note = try? #require(BoardPhase.skippedNote(count))
            #expect(note?.isEmpty == false, "\(count)")
            #expect(note?.contains("\(count)") == true, "\(count) is not named in its own note")
        }
        // Singular reads as English, not as "1 repositories".
        #expect(BoardPhase.skippedNote(1)?.contains("1 repository") == true)
        #expect(BoardPhase.skippedNote(2)?.contains("2 repositories") == true)
    }

    /// Nothing readable **and** something unreadable is criterion 4's other
    /// half — "says plainly that it cannot show any". It must not be `.empty`:
    /// "there is nothing to show" and "I could not look" are different answers,
    /// and #42 exists because they were once the same screen.
    @Test("Every row unreadable is a failure, never the empty state")
    func everyRowUnreadableIsNotEmpty() {
        let phase = BoardPhase.of(
            hasLoadedRepos: true, isReady: true, repoCount: 0,
            failure: nil, unreadableCount: 2)

        #expect(phase.isFailure)
        #expect(phase != .empty)
        #expect(phase == .unreadable(reason: BoardPhase.noneReadable(2)))
        #expect(phase.detail(status: "Ready.")?.contains("None of the 2") == true)
    }

    /// The singular of the same, because "None of the 1 repositories" is how
    /// that sentence goes wrong.
    @Test("A single unreadable row reads as one repository, not as none of one")
    func singleUnreadableRowReadsAsEnglish() {
        let phase = BoardPhase.of(
            hasLoadedRepos: true, isReady: true, repoCount: 0,
            failure: nil, unreadableCount: 1)
        #expect(phase.detail(status: "Ready.") == BoardPhase.noneReadable(1))
        #expect(BoardPhase.noneReadable(1).contains("The one repository"))
    }

    /// A genuinely empty store is still empty — the new argument must not have
    /// turned every empty board into a failure.
    @Test("An empty store with nothing skipped is still just empty")
    func emptyWithNoSkipsIsStillEmpty() {
        #expect(
            BoardPhase.of(
                hasLoadedRepos: true, isReady: true, repoCount: 0,
                failure: nil, unreadableCount: 0) == .empty)
    }

    @Test("A readable store with repositories draws the board and nothing else")
    func readyDrawsTheBoard() {
        let phase = BoardPhase.of(
            hasLoadedRepos: true, isReady: true, repoCount: 2, failure: nil)
        #expect(phase == .ready)
        #expect(phase.title == nil)
        #expect(phase.detail(status: "Ready.") == nil)
    }

    /// Every phase that is not the board itself says *something*: a titled
    /// screen with no words is the spinner this issue is about, wearing a
    /// different hat.
    @Test("Every non-board phase has a title")
    func everyScreenSpeaks() {
        let screens: [BoardPhase] = [.starting, .unreadable(reason: "x"), .empty]
        for phase in screens {
            #expect(phase.title?.isEmpty == false, "\(phase)")
        }
        #expect(BoardPhase.ready.title == nil)
    }
}
