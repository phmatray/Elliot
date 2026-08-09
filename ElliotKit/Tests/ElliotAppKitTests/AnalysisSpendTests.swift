import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// What the analysis footer and the collapsed lens strip are allowed to claim.
@Suite("Analysis spend and the footer's clamped text")
struct AnalysisSpendTests {

    private static func run(cost: Double?) -> SkillRun {
        SkillRun(
            cardID: nil, repoID: UUID(), kind: .analyzeRepo, prompt: "p", cwd: "/tmp",
            state: .succeeded, logPath: "/tmp/a.ndjson", stderrPath: "/tmp/a.log",
            totalCostUSD: cost,
            createdAt: Date(timeIntervalSince1970: 1_770_000_000)
        )
    }

    // MARK: - A nil is not a zero

    /// ⛔ The distinction the whole type exists for. `$0.00` for an analysis
    /// whose runs have not reported is a claim that it was free; absent is the
    /// honest rendering of "no reading", and it is the state a still-running
    /// analysis is in.
    @Test("Nothing to total is nothing shown, not a zero")
    func noReadingIsNotAZero() {
        #expect(AnalysisSpend.of([]) == nil)
        #expect(AnalysisSpend.of([Self.run(cost: nil), Self.run(cost: nil)]) == nil)
    }

    @Test("A whole reading totals, and says nothing about partiality")
    func aWholeReadingIsWhole() {
        let total = AnalysisSpend.of([Self.run(cost: 0.40), Self.run(cost: 0.60)])
        #expect(total == AnalysisSpend.Total(usd: 1.0, unrecorded: 0))
        #expect(total?.isPartial == false)
        #expect(AnalysisSpend.label(total!) == MoneyFormat.usd(1.0))
        #expect(AnalysisSpend.help(total!) == "What this analysis cost")
    }

    /// A total silently omitting two runs reads as the full spend — the
    /// false-negative family this repository has now named six times. It has to
    /// be marked **on screen**, so the mark is in `label`, not only in `help`.
    @Test("A partial reading is marked in the label, and counted in the tooltip")
    func aPartialReadingSaysSo() {
        let runs = [Self.run(cost: 0.25), Self.run(cost: nil), Self.run(cost: nil)]
        let total = try! #require(AnalysisSpend.of(runs))

        #expect(total.usd == 0.25)
        #expect(total.unrecorded == 2)
        #expect(total.isPartial)
        #expect(AnalysisSpend.label(total).hasSuffix("+"))
        #expect(AnalysisSpend.help(total).contains("2 runs"))

        // Singular is its own sentence rather than "1 runs".
        let one = try! #require(AnalysisSpend.of([Self.run(cost: 1), Self.run(cost: nil)]))
        #expect(AnalysisSpend.help(one).contains("1 run has"))
    }

    // MARK: - #220: a clamped label keeps a way back to its full text

    /// Criterion 5, as a shape gate on the source.
    ///
    /// The failures that land in the analysis footer are
    /// `error.localizedDescription` from a thrown start — the longest strings
    /// the slot ever shows, and the ones whose tail carries the actionable
    /// part. Clamped to two lines with no `.help(…)`, that tail is not merely
    /// hidden but **unrecoverable**: it reaches `os_log`, and nothing from this
    /// subsystem has come back out of `log show` at any level.
    ///
    /// Written the way `DrainDuplicationTests` and `DefaultActionTests` are
    /// written, and for the same reason: the claim is about a *modifier on a
    /// view*, which `swift test` cannot press, hover or see. What it can do is
    /// read the file and fail naming it.
    ///
    /// ⚠️ It gates every `.lineLimit(2)` in this file rather than the two known
    /// ones, so a third clamped label added later is covered without anybody
    /// remembering. The window is deliberately generous — a comment block sits
    /// between the clamp and the modifier — and the honest limit is that it
    /// cannot tell *which* string the `.help` carries.
    @Test("Every clamped label in the analysis panel carries a way back to its full text")
    func clampedLabelsKeepTheirTooltip() throws {
        let source = try String(
            contentsOfFile: Self.sourcePath("AnalysisPanelView.swift"), encoding: .utf8
        )
        let lines = source.components(separatedBy: "\n")
        let clamped = lines.indices.filter { lines[$0].contains(".lineLimit(2)") }

        // The gate is worthless if it is gating nothing — the same reason
        // `AnalysisPanelViewSourceTests` asserts its own file set is non-empty.
        #expect(!clamped.isEmpty, "no clamped label found — has the footer moved?")

        let uncovered = clamped.filter { index in
            !lines[index..<min(index + 16, lines.count)].contains { $0.contains(".help(") }
        }
        #expect(
            uncovered.isEmpty,
            Comment(rawValue:
                "clamped labels with no .help(…), so their tails are unreadable — "
                    + "AnalysisPanelView.swift lines "
                    + uncovered.map { String($0 + 1) }.joined(separator: ", "))
        )
    }

    /// The two sites #220 names, by the exact expression each must carry.
    ///
    /// Criterion 3: the tooltip's text is the message's own text. A literal
    /// here would be a second copy of a sentence `AnalysisFooterMessage`
    /// already decides, which is the shape this codebase keeps paying for.
    @Test("The footer's two clamped strings are quoted, never restated")
    func theTooltipIsTheMessageItself() throws {
        let source = try String(
            contentsOfFile: Self.sourcePath("AnalysisPanelView.swift"), encoding: .utf8
        )
        #expect(source.contains(".help(message.text)"))
        #expect(source.contains(".help(note)"))
    }

    private static func sourcePath(_ name: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ElliotAppKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ElliotKit
            .appendingPathComponent("Sources/ElliotAppKit/\(name)")
            .path
    }
}
