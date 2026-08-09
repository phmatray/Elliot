import Foundation
import Testing

@testable import ElliotModel

/// What a door does, what a menu item does, and why they are not the same act.
///
/// The whole of this type is four lines of transition, and it exists as a type
/// rather than two properties on `AppModel` because those four lines are a rule:
/// a view holding `face` directly would decide "does pressing this again close
/// it" afresh at every call site, which is how the same question came to have
/// three answers in `RunScheduler`, `Reconciler` and `PRWatcher` before #135.
@Suite("Console state")
struct ConsoleStateTests {

    // MARK: - 1. Shut is shut

    @Test("A new console is folded away, and open is exactly having a face")
    func opennessIsHavingAFace() {
        let state = ConsoleState()
        #expect(state.face == nil)
        #expect(!state.isOpen)

        for face in ConsoleFace.allCases {
            #expect(ConsoleState(face: face).isOpen)
        }
    }

    // MARK: - 2. What a door does

    @Test("Pressing the door of the face already showing folds the console away")
    func pressingTheSameDoorTwiceCloses() {
        var state = ConsoleState()
        state.press(.operations)
        #expect(state.face == .operations)

        state.press(.operations)
        #expect(state.face == nil, "a second press on the same door has to put the screen away")
    }

    @Test("Pressing another door switches face without ever passing through shut")
    func pressingAnotherDoorSwitchesWithoutClosing() {
        var state = ConsoleState(face: .operations)
        state.press(.preflight)
        #expect(
            state.face == .preflight,
            """
            switching doors closed the console. A fold-and-unfold animates a close the reader \
            did not ask for, between two screens they did
            """
        )
    }

    @Test("A door is a toggle from every face, and every pair of faces switches")
    func theDoorRuleHoldsAcrossEveryFace() {
        for face in ConsoleFace.allCases {
            var state = ConsoleState()
            state.press(face)
            #expect(state.face == face)
            state.press(face)
            #expect(state.face == nil)

            for other in ConsoleFace.allCases where other != face {
                var switching = ConsoleState(face: face)
                switching.press(other)
                #expect(switching.face == other)
            }
        }
    }

    // MARK: - 3. What a menu item does

    /// The distinction the two methods exist for. A menu item named
    /// "Operations" that closed Operations would do the opposite of what it says
    /// on every second use, and unlike a door it carries no figure to make the
    /// toggle read as one.
    @Test("Showing a face that is already showing leaves it showing")
    func showIsADestinationAndNotAToggle() {
        var state = ConsoleState(face: .archive)
        state.show(.archive)
        #expect(state.face == .archive, "a menu item closed the screen it names")

        state.show(.repositories)
        #expect(state.face == .repositories)
    }

    @Test("Closing folds the console away from any face")
    func closeAlwaysCloses() {
        for face in ConsoleFace.allCases {
            var state = ConsoleState(face: face)
            state.close()
            #expect(state.face == nil)
        }
    }

    // MARK: - 4. The height is a preference, not a session

    /// A preference that resets when you shut the thing is not a preference.
    @Test("The height survives a close, a re-open and a switch of face")
    func theHeightOutlivesTheFaceShowingIt() {
        var state = ConsoleState(face: .operations, height: .tall)

        state.close()
        #expect(state.height == .tall, "closing the console forgot the height the reader chose")

        state.press(.preflight)
        #expect(state.height == .tall)

        state.show(.archive)
        #expect(state.height == .tall)
    }

    @Test("The other height is the other one, and toggling twice is a no-op")
    func toggledIsAnInvolution() {
        #expect(ConsoleHeight.short.toggled == .tall)
        #expect(ConsoleHeight.tall.toggled == .short)
        for height in ConsoleHeight.allCases {
            #expect(height.toggled.toggled == height)
            #expect(height.toggled != height)
        }
    }

    // MARK: - 5. Persistence

    /// It is `Codable` because `Preferences` will carry the height, the way it
    /// carries the two panel spans. Pinned now so the shape that reaches disk is
    /// the shape that was designed, rather than whatever a later field addition
    /// leaves behind.
    @Test("A console state round-trips through JSON")
    func stateRoundTripsThroughJSON() throws {
        for face in ConsoleFace.allCases {
            for height in ConsoleHeight.allCases {
                let state = ConsoleState(face: face, height: height)
                let data = try JSONEncoder().encode(state)
                #expect(try JSONDecoder().decode(ConsoleState.self, from: data) == state)
            }
        }

        let shut = ConsoleState()
        let data = try JSONEncoder().encode(shut)
        #expect(try JSONDecoder().decode(ConsoleState.self, from: data) == shut)
    }
}
