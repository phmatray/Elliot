import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// What a board pass actually costs, before anyone caches anything (#282).
///
/// The issue proposes memoising `cards(in:)` under `@ObservationIgnored`, the
/// way `parsedBodies` memoises a parsed issue body — and then says, in its own
/// *What to watch*: **measure before caching; if it is cheap, record the
/// measurement instead.** This is that measurement, and it is the deliverable:
/// the numbers it prints are quoted on `AppModel.cards(in:)`, which is where a
/// future reader will be standing when they wonder.
///
/// ⛔ **Versioned and rerunnable on purpose.** A throwaway timing script whose
/// *number* is kept and whose *code* is not is a measurement nobody can check,
/// and the number then hardens into a fact in a comment. Re-run it with:
///
/// ```
/// cd ElliotKit && ELLIOT_MEASURE=1 swift test --filter CardsInColumnCostTests
/// ```
///
/// ⚠️ **Disabled unless that variable is set**, for two reasons that both matter
/// here. It is a wall-clock reading, and CLAUDE.md's testing discipline forbids
/// the suite asserting on absolute durations — they fail under load while the
/// code behaved perfectly. And at the largest size it is seconds of work, which
/// is not a cost every `swift test` should pay. What it asserts when it *does*
/// run is only that the work happened: a compiler free to discard the loop would
/// measure nothing and report it as speed.
@MainActor
@Suite("Cards in column cost")
struct CardsInColumnCostTests {

    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    /// A board of `cards` cards spread over `repos` repositories and all five
    /// columns, with the picker on "All repositories" — the expensive case, in
    /// which every column also groups.
    private func board(cards count: Int, repos repoCount: Int) -> AppModel {
        let repos = (0..<repoCount).map {
            Repo(
                path: "/tmp/repo\($0)", nameWithOwner: "phmatray/repo\($0)",
                defaultBranch: "main", displayName: "repo\($0)")
        }
        let columns = ElliotModel.Column.allCases
        let cards = (0..<count).map { index in
            Card(
                repoID: repos[index % repoCount].id,
                title: "card \(index)",
                column: columns[index % columns.count],
                orderIndex: Double(index),
                // Spread across a fortnight, so Done's horizon has something to
                // exclude and `shippingLog` has several days to bucket.
                columnEnteredAt: epoch.addingTimeInterval(-Double(index % 14) * 86_400),
                createdAt: epoch, updatedAt: epoch)
        }
        let model = AppModel()
        model.testOnlySeed(repos: repos, cards: cards)
        return model
    }

    @Test(
        "How long a board pass takes",
        .enabled(if: ProcessInfo.processInfo.environment["ELLIOT_MEASURE"] != nil))
    func cost() {
        let clock = ContinuousClock()
        let passes = 200
        var checksum = 0

        print("\n--- cards(in:) and a whole board pass, \(passes) repetitions each ---")
        for size in [100, 500, 2_000, 10_000] {
            let model = board(cards: size, repos: 20)

            // One `cards(in:)`, which is the filter and the sort the issue names.
            let single = clock.measure {
                for _ in 0..<passes {
                    checksum &+= model.cards(in: .backlog).count
                }
            }

            // A whole board pass: what one re-evaluation of all five columns now
            // costs, grouping and Done's day bucketing included. This is the
            // figure that matters — a selection change, a keystroke in the
            // analysis panel or a one-second `RunningStrip` tick re-evaluates the
            // row, not one property.
            let full = clock.measure {
                for _ in 0..<passes {
                    for column in ElliotModel.Column.allCases {
                        checksum &+= ColumnRows.of(column, model: model, foldedRepoIDs: []).rows.count
                    }
                }
            }

            print(
                "\(size) cards: cards(in:) \(Self.microseconds(single / passes)) µs"
                    + "  ·  board pass \(Self.microseconds(full / passes)) µs")
        }
        print("---")

        // Nothing above may be discarded as dead code, or this measures the
        // compiler's opinion of the loop rather than the board's cost.
        #expect(checksum > 0)
    }

    /// Microseconds, to one decimal.
    ///
    /// ⚠️ Both components, not just `attoseconds`. The first draft printed
    /// `attoseconds / 1_000_000_000` and labelled it µs — that is *nanoseconds*,
    /// and it silently drops everything past a second, so a reading would have
    /// been out by 1000× and wrapped to nothing on the slow case. A unit written
    /// in a label is not a unit the arithmetic performs.
    private static func microseconds(_ duration: Duration) -> String {
        let parts = duration.components
        let micros =
            Double(parts.seconds) * 1_000_000
            + Double(parts.attoseconds) / 1_000_000_000_000
        return String(format: "%.1f", micros)
    }
}
