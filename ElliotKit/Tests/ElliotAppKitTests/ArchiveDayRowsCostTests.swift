import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// What a keystroke in the Archive actually costs (#231).
///
/// `ArchiveState.dayRows` calls `shippingLog`, which buckets **and sorts** every
/// loaded card, and the view calls it once per `body` pass — so the work grows
/// with every *Load more* while the reason to redo it does not. #229 declined to
/// cache it on purpose, and both halves of that reasoning still hold: the cost
/// predates that diff, and a naive cache of day buckets would freeze *Today*,
/// because the buckets are `calendar.startOfDay` in the reader's own calendar.
///
/// So the issue asks for a measurement first and a decision either way — *"nobody
/// looked again" is not an outcome this issue may end in*. This is that
/// measurement, and it is the deliverable.
///
/// ⛔ **Versioned and rerunnable**, the shape `CardsInColumnCostTests` established
/// for #282 one screen over. A throwaway timing script whose *number* is kept and
/// whose *code* is not is a measurement nobody can check, and the number then
/// hardens into a fact in a comment.
///
/// ```
/// cd ElliotKit && ELLIOT_MEASURE=1 swift test --filter ArchiveDayRowsCostTests
/// ```
///
/// ⚠️ **Disabled unless that variable is set.** It is a wall-clock reading, and
/// CLAUDE.md's testing discipline forbids the suite asserting absolute durations
/// — they fail under load while the code behaved perfectly.
@Suite("Archive day rows cost")
struct ArchiveDayRowsCostTests {

    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    /// `count` finished cards spread over a fortnight, so `shippingLog` has
    /// several days to bucket rather than one.
    private func state(loaded count: Int) -> ArchiveState {
        let repoID = UUID()
        let cards = (0..<count).map { index in
            Card(
                repoID: repoID,
                title: "card \(index)",
                column: .done,
                orderIndex: Double(index),
                columnEnteredAt: epoch.addingTimeInterval(-Double(index % 14) * 86_400),
                createdAt: epoch, updatedAt: epoch)
        }
        var state = ArchiveState()
        state.append(cards, total: count + 1)
        return state
    }

    private var measuring: Bool { ProcessInfo.processInfo.environment["ELLIOT_MEASURE"] == "1" }

    /// The numbers quoted on `dayRows`. Release, Apple silicon.
    ///
    /// 25 is the first page, 250 is nine *Load more*s, 2 500 is a hundred — well
    /// past what the issue's own story describes ("first page, three *Load
    /// more*s, ten keystrokes"). 10 000 is included because a curve of three
    /// points can be read as linear when it is not.
    @Test("The cost of one dayRows call, at four sizes")
    func costCurve() {
        guard measuring else { return }
        for size in [25, 250, 2_500, 10_000] {
            let state = state(loaded: size)
            let calendar = Calendar.current
            let now = Date()
            // Warm, so the first reading is not the allocator's.
            _ = state.dayRows(now: now, calendar: calendar)

            let reps = size > 2_500 ? 20 : 200
            let start = ContinuousClock.now
            var sink = 0
            for _ in 0..<reps {
                sink += state.dayRows(now: now, calendar: calendar).count
            }
            let elapsed = ContinuousClock.now - start
            // Asserting the work happened at all: a compiler free to discard the
            // loop would measure nothing and report it as speed.
            #expect(sink > 0)
            let each = elapsed / reps
            print("  dayRows @ \(size) loaded: \(each) per call")
        }
    }

    /// The other half of criterion 1, and the half a timing cannot give.
    ///
    /// How often `shippingLog` runs is *count × cost*, and the count is one per
    /// `body` pass — which is a fact about the **call site**, not about a clock.
    /// So it is checked at the call site, in the source, the way
    /// `DrainDuplicationTests` and `DefaultActionTests` check theirs.
    ///
    /// ⚠️ It was already once-per-pass before this issue: #229 moved the call out
    /// of the `ForEach` and left a comment saying why. This gate is what stops it
    /// silently moving back in, which is the regression that would make the cost
    /// *per drawn day* rather than per pass.
    @Test("The Archive derives its day rows once per pass, never per row")
    func oncePerPass() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ElliotAppKit/ArchiveView.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        // The declaration is not a call — `func dayRows(…)` lives in this same
        // file, so a matcher that counts it reports two and reads as a
        // regression that is not there.
        let calls = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && $0.contains("dayRows(") && !$0.hasPrefix("func ") }

        #expect(calls.count == 1, "dayRows is derived \(calls.count) times in a pass")
        // And it must be the `ForEach`'s own argument — inside the loop it would
        // run once per day drawn.
        #expect(calls.first?.hasPrefix("ForEach(") == true)
    }

    /// One `shippingLog` per `dayRows`, so the cost above is the whole of it.
    @Test("One call derives the log once")
    func oneLogPerCall() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ElliotAppKit/ArchiveView.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let body = try #require(text.range(of: "func dayRows(now: Date, calendar: Calendar)"))
        let scope = String(text[body.upperBound...].prefix(400))
        #expect(scope.components(separatedBy: "shippingLog(").count - 1 == 1)
    }
}
