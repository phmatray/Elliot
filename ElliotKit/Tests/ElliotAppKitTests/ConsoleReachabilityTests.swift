import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// One screen, one way in.
///
/// The console migrates six screens out of `Window` scenes, two at a time, and
/// the mistake available at every step is the same: add the door, forget to
/// delete the scene. Nothing then fails. The screen simply has two ways in, one
/// of which covers the board it reports on — which is the shape #151 retired the
/// Analysis window for, and #232 measured the cost of.
///
/// A source-reading gate in the `DrainDuplicationTests` idiom, because what is
/// wrong in that state is a *shape*: both paths work, and both look correct from
/// inside the app.
@MainActor
@Suite("Console reachability")
struct ConsoleReachabilityTests {

    private static func source(_ target: String, _ file: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ElliotAppKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ElliotKit
            .appendingPathComponent("Sources/\(target)/\(file)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The scene ids `ElliotApp` declares. A declaration starts its line; an
    /// `openWindow(id:)` call site never does — see `WindowCaptureTests`, where
    /// reading this loosely hid a deleted scene.
    private static func declaredScenes(in text: String) -> Set<String> {
        var ids: Set<String> = []
        for line in text.split(separator: "\n")
        where line.trimmingCharacters(in: .whitespaces).hasPrefix("Window(") {
            guard let start = line.range(of: "id: \"") else { continue }
            let rest = line[start.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { continue }
            ids.insert(String(rest[..<end]))
        }
        return ids
    }

    /// Faces a reader can actually reach: a door in the status bar
    /// (`face: .name`) or a menu item (`showConsoleFace(.name)`).
    private static func reachableFaces(in sources: [String]) -> Set<ConsoleFace> {
        var faces: Set<ConsoleFace> = []
        for face in ConsoleFace.allCases {
            let door = "face: .\(face.rawValue)"
            let item = "showConsoleFace(.\(face.rawValue))"
            if sources.contains(where: { $0.contains(door) || $0.contains(item) }) {
                faces.insert(face)
            }
        }
        return faces
    }

    // MARK: - 1. The invariant

    @Test("A screen reachable as a console face has no window scene left")
    func aFaceAndItsSceneAreNeverBothReachable() throws {
        let app = try Self.source("ElliotApp", "ElliotApp.swift")
        let board = try Self.source("ElliotAppKit", "BoardView.swift")

        let scenes = Self.declaredScenes(in: app)
        let faces = Self.reachableFaces(in: [app, board])
        #expect(!faces.isEmpty, "parsed no reachable faces; the parser has drifted from the code")

        let both = faces.filter { scenes.contains($0.rawValue) }
        #expect(
            both.isEmpty,
            """
            \(both.map(\.rawValue).sorted().joined(separator: ", ")) is reachable twice — as a \
            console face and as a Window scene. Delete the scene: two ways into one screen means \
            one of them covers the board it reports on, and board_screenshot still reports the \
            scene as merely shut
            """
        )
    }

    /// The other direction, and the one that loses a screen outright: a scene
    /// deleted with no door put in its place.
    @Test("A screen that has lost its scene is reachable as a face")
    func aDeletedSceneLeavesADoorBehind() throws {
        let app = try Self.source("ElliotApp", "ElliotApp.swift")
        let board = try Self.source("ElliotAppKit", "BoardView.swift")

        let scenes = Self.declaredScenes(in: app)
        let faces = Self.reachableFaces(in: [app, board])

        for face in ConsoleFace.allCases where !scenes.contains(face.rawValue) {
            #expect(
                faces.contains(face),
                """
                \(face.rawValue) has no Window scene and no way into the console either. \
                It is a screen nobody can open
                """
            )
        }
    }

    // MARK: - 2. Where the migration stands

    /// A ratchet, not a description. It fails in **both** directions on purpose:
    /// forwards it says which screens still owe a migration, and backwards it
    /// catches a face quietly reverting to a window.
    @Test("Every screen but the board is a console face, and one scene is left")
    func theMigrationIsWhereItSaysItIs() throws {
        let app = try Self.source("ElliotApp", "ElliotApp.swift")
        let board = try Self.source("ElliotAppKit", "BoardView.swift")

        #expect(Set(Self.reachableFaces(in: [app, board])) == Set(ConsoleFace.allCases))
        #expect(
            Self.declaredScenes(in: app) == ["board"],
            """
            the console migration is complete and this is its ratchet: one scene, the board. \
            A new Window scene here needs a reason that survives #232 — an agent has no click, \
            so a window it declares is a screen no agent can ever open
            """
        )
    }

    /// ⚠️ `reachableFaces` merges the two ways in, so it cannot tell a face with
    /// a door from a face with a menu item — and for `dismissed` the difference
    /// is the whole point. Its door is **conditional**: `DismissalDigest.figure`
    /// is nil at zero, following the queue and the sweep, because a permanent
    /// "0 dismissed" is furniture. A face whose only way in vanishes with its
    /// own contents is a face nobody can open to find out that it is empty — and
    /// the merged helper would call it reachable on the strength of a door that
    /// is not on screen.
    ///
    /// So `dismissed` needs **both**, and this asserts them one each. The door
    /// half is #334's criterion 3 — *the import summary's dismissed count leads
    /// to that list rather than only stating a number* — which is otherwise
    /// unpinned: a status-bar figure is layout, `swift test` cannot see one, and
    /// deleting it leaves every behavioural test in this package green while the
    /// feature reverts to the dead end it was written to close.
    @Test("The Dismissed face has both ways in, and each answers a different moment")
    func aConditionalDoorIsBackedByAMenuItem() throws {
        let app = try Self.source("ElliotApp", "ElliotApp.swift")
        let board = try Self.source("ElliotAppKit", "BoardView.swift")

        #expect(
            app.contains("showConsoleFace(.dismissed)"),
            """
            the Dismissed face has no menu item, and its status-bar figure is absent \
            whenever there is nothing dismissed — so at zero there is no way in at all
            """
        )
        #expect(
            board.contains("face: .dismissed"),
            """
            the status bar has no Dismissed door. The count of suppressed items is back to \
            being a number with nothing to press, which is #334's whole subject
            """
        )
    }

    // MARK: - 3. The funnel

    @Test("The model's console methods are the transitions, not a second copy of them")
    func theModelJustForwards() {
        let model = AppModel()

        model.pressConsoleDoor(.operations)
        #expect(model.console.face == .operations)
        model.pressConsoleDoor(.operations)
        #expect(model.console.face == nil, "the door stopped being a toggle on the way through")

        model.showConsoleFace(.nextSteps)
        model.showConsoleFace(.nextSteps)
        #expect(model.console.face == .nextSteps, "the menu item closed the screen it names")

        model.closeConsole()
        #expect(model.console.face == nil)
    }

    @Test("The height is a preference and outlives the screen showing it")
    func theHeightSurvivesTheConsoleClosing() {
        let model = AppModel()
        #expect(model.consoleHeightToggleTitle == "Lengthen Console")

        model.toggleConsoleHeight()
        #expect(model.console.height == .tall)
        #expect(model.consoleHeightToggleTitle == "Shorten Console")

        model.pressConsoleDoor(.operations)
        model.closeConsole()
        #expect(model.console.height == .tall, "folding the console forgot the chosen height")
    }

    /// Not persisted, deliberately — a board that reopened onto Operations would
    /// report a previous session's machine state over the columns the reader
    /// came back for.
    @Test("A fresh model starts with the console folded away")
    func theConsoleStartsShut() {
        #expect(!AppModel().console.isOpen)
    }
}
