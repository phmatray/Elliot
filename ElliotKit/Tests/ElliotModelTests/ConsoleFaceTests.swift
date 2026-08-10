import Foundation
import Testing

@testable import ElliotModel

/// The console's vocabulary, and the one promise it has to keep while both
/// worlds coexist.
///
/// `ConsoleFace` names screens that are still `Window` scenes today, so almost
/// nothing here is about behaviour — it is about a *migration* staying honest.
/// The failure this suite exists to catch is silent by construction: a screen
/// that stops being a window and never becomes a face simply disappears, and
/// nothing else in the package has an opinion about that.
@Suite("Console faces")
struct ConsoleFaceTests {

    // MARK: - 1. No screen may vanish

    /// The union, not either half — because the two halves are supposed to move.
    /// `ElliotWindows.all` shrinks as the console grows, and this set did not
    /// through that whole migration.
    ///
    /// ⚠️ **`nextSteps` left this set in #304, and this is the comment its own
    /// failure message asked for.** Up next did not become a seventh way of being
    /// reached — it stopped being a screen. It is the acting band of Operations,
    /// a peer of Workers, Waiting and Spending, and `OperationsView` renders it as
    /// `UpNextBand`. Keeping the name here to hold the literal still would make a
    /// set called *every screen Elliot has* assert a screen that no longer exists,
    /// which is the opposite of what it was written to catch.
    ///
    /// Nothing observable moved with it: these raw values reach no runtime caller
    /// — `board_screenshot` resolves through `ElliotWindows.all`, which has said
    /// `board` alone since the console landed — so `window=nextSteps` answered
    /// `window_not_found` before this change and answers it after.
    @Test("Every screen Elliot has is either a window or a console face")
    func noScreenVanishesBetweenTheTwoWorlds() {
        #expect(
            ConsoleFace.allScreens == [
                "board", "repositories", "operations", "preflight", "archive", "newStory",
            ],
            """
            a screen has appeared or disappeared. If a window became a face, it belongs in \
            ConsoleFace; if it went somewhere else entirely, say where in this test rather \
            than deleting the name — as #304 did for nextSteps, which is now a band of \
            Operations rather than a screen
            """
        )
    }

    @Test("The board is not a face: it is the window the console unfolds inside")
    func theBoardIsNotAFace() {
        #expect(!ConsoleFace.allCases.map(\.rawValue).contains("board"))
        #expect(ConsoleFace(rawValue: "board") == nil)
    }

    // MARK: - 2. The names are the ones agents already use

    /// The compatibility promise. `board_screenshot window=<id>` is the only way
    /// an agent has ever named a screen, and #232 is about that call being
    /// unable to reach any of them. The fix must not also rename them.
    ///
    /// ⚠️ **A frozen literal, and the one place in this suite where restating
    /// the enum is correct.** It checked `ElliotWindows.all.contains(…)` until
    /// the console's first wave, which held only while every face was still a
    /// window; the moment `operations` and `nextSteps` stopped being scenes, the
    /// check started asserting that the migration had not happened. What the
    /// promise is actually about is **history** — the ids these screens were
    /// published under — and history does not follow the source. So this list is
    /// deliberately not derived from anything, and a face whose raw value must
    /// change has to change it here too, in front of a comment explaining what
    /// breaks for the caller.
    ///
    /// ⚠️ **`nextSteps` is out (#304), and it is worth being precise about why
    /// that is not the renaming this test forbids.** A rename leaves the screen
    /// standing under a different id, so a caller that knew the old one is sent
    /// nowhere; a *retirement* is the screen ceasing to exist, and no id can be
    /// kept honest for it. Up next is a band of Operations now. What the promise
    /// costs here is nothing measurable: the only caller is `board_screenshot`,
    /// which reads `ElliotWindows.all` and has been answering `window_not_found`
    /// for every face since the console landed.
    @Test("Every face's raw value is the id that screen was published under")
    func rawValuesAreThePublishedIDs() {
        let published: Set<String> = [
            "repositories", "operations", "preflight", "archive", "newStory",
        ]
        #expect(
            Set(ConsoleFace.allCases.map(\.rawValue)) == published,
            """
            a face's raw value has moved away from the id agents pass to board_screenshot. \
            Renaming one is a breaking change to the only caller this migration exists to serve
            """
        )
    }

    @Test("A face round-trips through its raw value, which is also its identity")
    func facesRoundTripThroughTheirRawValue() {
        for face in ConsoleFace.allCases {
            #expect(ConsoleFace(rawValue: face.rawValue) == face)
            #expect(face.id == face.rawValue)
        }
        #expect(ConsoleFace(rawValue: "nosuchscreen") == nil)
    }

    // MARK: - 3. Titles

    @Test("Every face is titled, and no two share a title")
    func titlesAreDistinctAndPresent() {
        let titles = ConsoleFace.allCases.map(\.title)
        for title in titles {
            #expect(!title.isEmpty)
        }
        #expect(
            Set(titles).count == titles.count,
            "two doors with the same label are two doors a reader cannot tell apart"
        )
    }

    /// Taken from the `Window(_:id:)` titles rather than invented — a reader who
    /// learned to call a screen by its window's name must still find it under
    /// that name when it stops being a window.
    ///
    /// "Up next" is no longer among them and has kept its name anyway: it is the
    /// `ConsoleLabel` on the Operations band that absorbed it (#304), so the
    /// reader still reads the same two words for the same list.
    @Test("The titles are the window titles, including the one that is not a capitalised pair")
    func titlesMatchTheWindowTitlesTheyReplace() {
        #expect(ConsoleFace.newStory.title == "New story")
        #expect(ConsoleFace.repositories.title == "Repositories")
        #expect(ConsoleFace.operations.title == "Operations")
        #expect(ConsoleFace.preflight.title == "Preflight")
        #expect(ConsoleFace.archive.title == "Archive")
    }
}
