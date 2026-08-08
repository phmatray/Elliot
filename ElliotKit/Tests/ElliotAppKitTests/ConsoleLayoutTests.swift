import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// The arithmetic behind the console that unfolds from the status bar.
///
/// `PanelLayoutTests`' vertical twin, and it exists for the reason that suite
/// states: `.inspector()` shipped three times green and wrecked the window three
/// times, so the numbers a placement is built from are pinned here where a test
/// can hold them.
///
/// What is different vertically is the whole subject of this suite. The board
/// scrolls sideways, so `PanelLayout.contentWidth` is *allowed* to overflow the
/// window and says so. Nothing scrolls down: height the console takes is height
/// the board loses, and a column pushed past the bottom is a column whose cards
/// cannot be reached. Every assertion below is therefore ultimately about one
/// claim — **the board's floor is never breached** — checked at real window
/// heights rather than at a single convenient one.
@Suite("Console layout")
struct ConsoleLayoutTests {

    /// The content heights every assertion is replayed at: the shortest window
    /// the console can open in at all, the 1000×600 minimum window, the 1640×840
    /// default, and a large display. Content height is what the board's
    /// `GeometryReader` reports — the window less its title band — so these are
    /// deliberately not window heights.
    private let contentHeights: [CGFloat] = [408, 548, 788, 1400]

    /// Below this the console cannot open: 240 for the board, 140 for the
    /// console, 28 for the status bar.
    private let shortestThatOpens: CGFloat = 408

    private func isClose(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.001 }

    // MARK: - 1. The floors

    @Test("The console never takes the board below its floor, at any height or window")
    func theBoardFloorIsNeverBreached() {
        for contentHeight in contentHeights {
            for height in ConsoleHeight.allCases {
                let board = ConsoleLayout.boardHeight(contentHeight: contentHeight, console: height)
                #expect(
                    board >= ConsoleLayout.minBoardHeight,
                    """
                    at \(contentHeight)pt of content the \(height) console left the board \
                    \(board)pt, under its \(ConsoleLayout.minBoardHeight)pt floor — cards below \
                    the fold cannot be reached, because nothing here scrolls down
                    """
                )
            }
        }
    }

    @Test("The two of them account for every point above the status bar")
    func theHeightsSumToWhatIsAvailable() {
        for contentHeight in contentHeights {
            let available = ConsoleLayout.availableHeight(contentHeight: contentHeight)
            for height in ConsoleHeight.allCases {
                let console = ConsoleLayout.consoleHeight(height, contentHeight: contentHeight)
                let board = ConsoleLayout.boardHeight(contentHeight: contentHeight, console: height)
                #expect(
                    isClose(console + board, available),
                    """
                    \(console) + \(board) is not \(available): a gap here is a strip of window \
                    neither of them is drawing
                    """
                )
            }
        }
    }

    @Test("A shut console leaves the board everything above the status bar")
    func aShutConsoleCostsTheBoardNothing() {
        for contentHeight in contentHeights {
            #expect(
                ConsoleLayout.boardHeight(contentHeight: contentHeight, console: nil)
                    == ConsoleLayout.availableHeight(contentHeight: contentHeight)
            )
        }
        // And that `nil` is a real case rather than `.short` spelled differently.
        #expect(
            ConsoleLayout.boardHeight(contentHeight: 788, console: nil)
                != ConsoleLayout.boardHeight(contentHeight: 788, console: .short)
        )
    }

    // MARK: - 2. The shares

    @Test("Where there is room, the console is a third of the height or a half of it")
    func theDesignedSharesHoldWhereTheyFit() {
        // 1400pt of content: 1372 above the status bar, and the board's floor is
        // nowhere near binding, so both designs get exactly what they ask for.
        let available = ConsoleLayout.availableHeight(contentHeight: 1400)
        #expect(
            isClose(ConsoleLayout.consoleHeight(.short, contentHeight: 1400), available / 3)
        )
        #expect(
            isClose(ConsoleLayout.consoleHeight(.tall, contentHeight: 1400), available / 2)
        )
    }

    @Test("The tall console is never shorter than the short one")
    func tallIsNeverShorterThanShort() {
        for contentHeight in contentHeights {
            #expect(
                ConsoleLayout.consoleHeight(.tall, contentHeight: contentHeight)
                    >= ConsoleLayout.consoleHeight(.short, contentHeight: contentHeight),
                "at \(contentHeight)pt the two designs are the wrong way round"
            )
        }
    }

    /// The ceiling is what makes the floor above hold, so it has to be shown
    /// actually biting rather than merely never being needed.
    @Test("At the minimum window the ceiling binds and the share does not get what it asked for")
    func theCeilingBitesAtSmallWindows() {
        // 548pt of content — the 1000×600 minimum window — is 520 above the bar.
        // Half of that is 260, and the board's floor leaves exactly 280, so tall
        // is unclamped here while the *shortest* window below clamps both.
        #expect(isClose(ConsoleLayout.consoleHeight(.tall, contentHeight: 548), 260))

        // At the shortest window that opens at all, the ceiling is 140 and both
        // designs are cut to it: a third of 380 is 126.7 (raised to the console's
        // own 140 floor) and half is 190 (cut to the ceiling's 140).
        let short = ConsoleLayout.consoleHeight(.short, contentHeight: shortestThatOpens)
        let tall = ConsoleLayout.consoleHeight(.tall, contentHeight: shortestThatOpens)
        #expect(isClose(short, 140))
        #expect(isClose(tall, 140))
        #expect(
            isClose(ConsoleLayout.boardHeight(contentHeight: shortestThatOpens, console: .tall), 240),
            "the shortest console that opens must leave the board exactly its floor"
        )
    }

    /// ⚠️ The documented consequence of clamping in this order: the console is
    /// allowed to come back under its own minimum, because the board's floor
    /// wins outright. A test that did not pin this would let someone "fix" it
    /// with a trailing `max(minConsoleHeight, …)` and push cards off the bottom.
    @Test("On a window too short to open, the arithmetic yields to the board rather than inverting")
    func theBoardWinsOutrightBelowTheGate() {
        // Every height, above the gate and below it. The ceiling is what "the
        // board's floor wins" *means*, so it is the ceiling that is asserted —
        // an earlier version of this test asserted the console's own minimum
        // instead, which both clamp orders satisfy at exactly 140 and which
        // therefore proved nothing.
        for contentHeight in contentHeights + [0, 100, 268, 300, 407] {
            let available = ConsoleLayout.availableHeight(contentHeight: contentHeight)
            let ceiling = max(0, available - ConsoleLayout.minBoardHeight)
            for height in ConsoleHeight.allCases {
                let console = ConsoleLayout.consoleHeight(height, contentHeight: contentHeight)
                #expect(console >= 0, "a negative console height is not a height")
                #expect(
                    console <= ceiling + 0.001,
                    """
                    at \(contentHeight)pt the \(height) console came back \(console)pt against a \
                    \(ceiling)pt ceiling, so the board is under its floor. The clamp order is \
                    load-bearing: a max(minConsoleHeight, …) applied last grows the console \
                    straight through it
                    """
                )
            }
        }
    }

    // MARK: - 3. The gate

    @Test("The console opens exactly when the board's floor and its own both fit")
    func canOpenIsTheSumOfTheTwoFloors() {
        #expect(ConsoleLayout.canOpen(contentHeight: shortestThatOpens))
        #expect(!ConsoleLayout.canOpen(contentHeight: shortestThatOpens - 1))
        #expect(!ConsoleLayout.canOpen(contentHeight: 0))
        for contentHeight in contentHeights {
            #expect(ConsoleLayout.canOpen(contentHeight: contentHeight))
        }
    }

    /// The 1000×600 minimum window is the case this whole gate was measured
    /// against, and the answer decided that #232's fix needs no `minHeight`
    /// change: the console fits in the smallest window Elliot allows.
    @Test("The console fits in the smallest window the app allows")
    func theMinimumWindowIsTallEnough() {
        // 600pt of window is 548 of content once the title band is reserved, and
        // the console opens with 346pt of board left over.
        #expect(ConsoleLayout.canOpen(contentHeight: 548))
        #expect(
            ConsoleLayout.boardHeight(contentHeight: 548, console: .short)
                > ConsoleLayout.minBoardHeight,
            "if this ever fails, the board window's minHeight has to rise with it"
        )
    }

    @Test("A door that will not open says why, and one that will says nothing")
    func theRefusalIsAnExplanationAndOnlyWhenItIsTrue() throws {
        #expect(ConsoleLayout.refusal(contentHeight: shortestThatOpens) == nil)
        for contentHeight in contentHeights {
            #expect(ConsoleLayout.refusal(contentHeight: contentHeight) == nil)
        }

        let refusal = try #require(ConsoleLayout.refusal(contentHeight: 300))
        #expect(refusal.contains("408pt"), "the sentence must name the height that works")
    }

    // MARK: - 4. Snapping

    @Test("A drag that never moves leaves the height alone, at either setting")
    func aZeroDragIsNeverAResize() {
        for contentHeight in contentHeights {
            for height in ConsoleHeight.allCases {
                #expect(
                    ConsoleLayout.snapped(from: height, translation: 0, contentHeight: contentHeight)
                        == height,
                    "a click on the handle resized the console behind the reader's back"
                )
            }
        }
    }

    @Test("Dragging the top edge upwards grows the console, and downwards shrinks it")
    func theSignIsFlippedOnceAndInTheRightDirection() {
        // 788pt of content: short is 253, tall is 380, so a 200pt drag either way
        // is unambiguous.
        #expect(ConsoleLayout.snapped(from: .short, translation: -200, contentHeight: 788) == .tall)
        #expect(ConsoleLayout.snapped(from: .tall, translation: 200, contentHeight: 788) == .short)
        // And that a nudge the wrong side of halfway does not cross over.
        #expect(ConsoleLayout.snapped(from: .short, translation: -10, contentHeight: 788) == .short)
        #expect(ConsoleLayout.snapped(from: .tall, translation: 10, contentHeight: 788) == .tall)
    }

    @Test("Every drag lands on a designed height, never between them")
    func snappingOnlyEverYieldsADesignedHeight() {
        for contentHeight in contentHeights {
            for height in ConsoleHeight.allCases {
                for translation in stride(from: CGFloat(-600), through: 600, by: 25) {
                    let landed = ConsoleLayout.snapped(
                        from: height, translation: translation, contentHeight: contentHeight)
                    #expect(ConsoleHeight.allCases.contains(landed))
                }
            }
        }
    }

    /// At the shortest window that opens, the ceiling has collapsed both designs
    /// onto 140pt — so there is no drag that can distinguish them, and picking
    /// one would be picking for the reader.
    @Test("Where the ceiling has collapsed both designs, a drag changes nothing")
    func aCollapsedRangeLeavesThePreferenceAlone() {
        #expect(
            isClose(
                ConsoleLayout.consoleHeight(.short, contentHeight: shortestThatOpens),
                ConsoleLayout.consoleHeight(.tall, contentHeight: shortestThatOpens)
            ),
            "this test is only meaningful while the two heights coincide here"
        )
        for translation in [CGFloat(-300), -50, 50, 300] {
            #expect(
                ConsoleLayout.snapped(
                    from: .tall, translation: translation, contentHeight: shortestThatOpens) == .tall
            )
        }
    }

    @Test("On a window too short to open, a drag is left alone rather than repaired")
    func snappingBelowTheGateIsANoOp() {
        for height in ConsoleHeight.allCases {
            #expect(
                ConsoleLayout.snapped(from: height, translation: -400, contentHeight: 200) == height
            )
        }
    }
}
