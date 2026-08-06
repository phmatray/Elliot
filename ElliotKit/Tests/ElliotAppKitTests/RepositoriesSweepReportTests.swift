import Foundation
import Testing

@testable import ElliotAppKit

/// The one thing about the sweep's report that a test can hold.
///
/// `swift test` cannot see layout — this project has paid for pretending
/// otherwise four times (#47, #50, #52, #53). What it *can* see is the shape of
/// the source, which is how `BoardAccessibilityTests` pins the reduce-motion
/// rule, and the hazard here has that same shape: the report lists **every**
/// skipped repository, and on a real portfolio that is two hundred lines
/// rendered inside a `safeAreaInset` header. A header free to grow to fit them
/// eats the page it is a header for.
///
/// So the rule is: the report scrolls inside a bounded frame. Not "it looked
/// fine when someone opened it with four repositories registered" — that is
/// exactly the sample size under which this class of bug survives review.
@Suite("Repositories sweep report")
struct RepositoriesSweepReportTests {

    private var source: String {
        get throws {
            let path = URL(filePath: #filePath)  // …/Tests/ElliotAppKitTests/<this file>
                .deletingLastPathComponent()  // …/Tests/ElliotAppKitTests
                .deletingLastPathComponent()  // …/Tests
                .deletingLastPathComponent()  // …/ElliotKit
                .appending(path: "Sources/ElliotAppKit/RepositoriesView.swift")
            return try String(contentsOf: path, encoding: .utf8)
        }
    }

    @Test("The sweep report is scrolled inside a bounded frame, never free to grow")
    func theReportIsBounded() throws {
        let source = try source
        #expect(source.contains("model.lastSyncSummary"), "the report is still rendered here")

        // The `ScrollView` that holds the report, and a `maxHeight` on it. Both,
        // and adjacent: a ScrollView with no ceiling grows to its content, and a
        // ceiling with no ScrollView clips the tail — which is the silent
        // truncation the summary exists to prevent.
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        let scrollIndex = lines.firstIndex { $0.contains("ScrollView {") }
        let boundIndex = lines.firstIndex { $0.contains(".frame(maxHeight:") }
        #expect(scrollIndex != nil, "the report scrolls")
        #expect(boundIndex != nil, "the report has a ceiling")
        if let scrollIndex, let boundIndex {
            #expect(boundIndex > scrollIndex, "the ceiling belongs to the scroll view")
        }
    }

    @Test("Both halves of the report are rendered — the failures and the skips")
    func nothingIsDroppedFromTheReport() throws {
        let source = try source
        #expect(source.contains("summary.failed"), "failures are listed")
        #expect(source.contains("summary.skipped"), "skips are listed")
        // No `.prefix(`/`.first(` between the summary and the rows: a report that
        // showed the first N and said nothing about the rest would read exactly
        // like a sweep that touched only N.
        #expect(!source.contains("summary.skipped.prefix"))
        #expect(!source.contains("summary.failed.prefix"))
    }
}
