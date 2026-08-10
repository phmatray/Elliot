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

    // MARK: - 2b. A door that opens nothing

    /// Every `.swift` under both targets that can put a control on screen, with
    /// `//` comments cut away.
    ///
    /// ⚠️ Comments are stripped for the reason `AnalysisPanelViewSourceTests`
    /// records: three files here *discuss* `openWindow` at length, including the
    /// one that stopped calling it, and a gate matching raw text would fail on
    /// the explanation of the rule it enforces.
    ///
    /// ⚠️ An empty walk is a failure, not a pass — a renamed directory would
    /// otherwise silently reduce this gate's coverage while it stayed green.
    private static func viewCode() throws -> [(file: String, code: String)] {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ElliotAppKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ElliotKit
            .appendingPathComponent("Sources")
        var found: [(file: String, code: String)] = []
        for target in ["ElliotAppKit", "ElliotApp"] {
            let directory = sources.appendingPathComponent(target)
            let names = try FileManager.default
                .contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasSuffix(".swift") }
                .sorted()
            #expect(!names.isEmpty, "\(target) contributed no files; has it moved or been renamed?")
            for name in names {
                let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
                let code = text.components(separatedBy: "\n")
                    .map { line -> String in
                        guard let comment = line.range(of: "//") else { return line }
                        return String(line[line.startIndex..<comment.lowerBound])
                    }
                    .joined(separator: "\n")
                found.append((file: "\(target)/\(name)", code: code))
            }
        }
        return found
    }

    /// ⛔ **A button that opens a scene nobody declares does nothing, silently.**
    ///
    /// Found in #304 while folding Up next in: `OperationsView` carried four
    /// `openWindow(id:)` calls — three naming `preflight`, one naming
    /// `nextSteps` — and every one of those scenes had been deleted by an earlier
    /// console wave. SwiftUI logs an unknown id and returns, so *Open Preflight*,
    /// *Change the limits* and *Set a ceiling* had been inert for as long as the
    /// console had existed, on the screen whose whole job is to be acted on.
    ///
    /// The two directions this suite already guards are a face with a scene still
    /// standing, and a scene deleted with no face put in its place. This is the
    /// third: a **caller** left behind by a scene deletion. It is the one the
    /// console migration could produce every wave, because a deleted scene takes
    /// its declaration with it and leaves every `openWindow` naming it compiling
    /// perfectly.
    @Test("Every openWindow call names a scene ElliotApp actually declares")
    func noViewOpensASceneThatDoesNotExist() throws {
        let app = try Self.source("ElliotApp", "ElliotApp.swift")
        let scenes = Self.declaredScenes(in: app)
        #expect(!scenes.isEmpty, "parsed no scenes; the parser has drifted from ElliotApp.swift")

        var opened: [(site: String, id: String)] = []
        for file in try Self.viewCode() {
            var rest = Substring(file.code)
            while let call = rest.range(of: "openWindow(id: \"") {
                let after = rest[call.upperBound...]
                guard let end = after.firstIndex(of: "\"") else { break }
                opened.append((site: file.file, id: String(after[..<end])))
                rest = after[end...]
            }
        }

        // A negative needs its positive witness: a parser that matched nothing
        // would make the claim below vacuously true for ever.
        #expect(
            !opened.isEmpty,
            "parsed no openWindow(id:) call sites at all — the matcher has drifted from the code")

        let dangling = opened.filter { !scenes.contains($0.id) }
        #expect(
            dangling.isEmpty,
            """
            \(dangling.map { "\($0.site) opens \"\($0.id)\"" }.joined(separator: " · ")) — \
            no such scene is declared in ElliotApp.swift, which declares \(scenes.sorted()). \
            SwiftUI logs an unknown id and does nothing, so the control is dead while looking \
            perfectly alive. A screen that became a console face is reached with \
            model.showConsoleFace(_:) instead (#304)
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

        model.showConsoleFace(.archive)
        model.showConsoleFace(.archive)
        #expect(model.console.face == .archive, "the menu item closed the screen it names")

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
