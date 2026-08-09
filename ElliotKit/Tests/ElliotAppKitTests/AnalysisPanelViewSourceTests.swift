import Foundation
import Testing

/// The analysis screens may not ask the board's toolbar picker which repository
/// they are about (#213).
///
/// The behavioural tests in `AnalysisRepoScopeTests` prove the **rule**; this
/// one pins the **shape**, and the shape is what the next feature undoes without
/// noticing — by adding a sub-view that reaches for `model.selectedRepoID`
/// because that is what the file used to do. Nothing would fail: the new view
/// would render the picked repository, which is right in setup and wrong for
/// every open analysis, and no test asserts about a view that does not exist
/// yet.
///
/// The idiom is the one `DrainDuplicationTests` and `CaretAnchorTests` already
/// use here, for the reason `CLAUDE.md` states: *a gate that is not a test is a
/// gate nobody re-runs.*
@Suite("The analysis panel's source")
struct AnalysisPanelViewSourceTests {

    /// Where the views live, found from this file rather than from the working
    /// directory — `swift test` promises nothing about the latter.
    private static var viewSources: URL {
        URL(filePath: #filePath)          // …/Tests/ElliotAppKitTests/<this file>
            .deletingLastPathComponent()  // …/Tests/ElliotAppKitTests
            .deletingLastPathComponent()  // …/Tests
            .deletingLastPathComponent()  // …/ElliotKit
            .appending(path: "Sources/ElliotAppKit")
    }

    /// Every `Analysis*.swift` under `Sources/ElliotAppKit`, rather than the one
    /// file the defect was found in.
    ///
    /// Discovered rather than listed, so a sub-view split out of the panel
    /// tomorrow is covered on the day it is created — which is the only day the
    /// mistake is easy to make.
    private static func analysisSources() throws -> [(name: String, source: String)] {
        let directory = viewSources
        let names = try FileManager.default
            .contentsOfDirectory(atPath: directory.path(percentEncoded: false))
            .filter { $0.hasPrefix("Analysis") && $0.hasSuffix(".swift") }
            .sorted()
        return try names.map {
            ($0, try String(contentsOf: directory.appending(path: $0), encoding: .utf8))
        }
    }

    /// The line with any `//` comment removed.
    ///
    /// ⚠️ **Load-bearing, and the trap this kind of test walks into.** Both
    /// `AnalysisPanelView` and `AnalysisSession` *document* why they do not read
    /// the picker, naming it — so a gate that matched raw text would fail on the
    /// explanation of the very rule it enforces, and the obvious way to make it
    /// pass would be to delete the explanation. `CLAUDE.md` records the same
    /// hazard from #186: a string gate over prose *"can tell neither a claim
    /// from a mention nor a live claim from a quoted one"*. Cutting at `//`
    /// tells them apart for this file set, where no string literal contains one.
    private static func code(_ line: String) -> String {
        guard let comment = line.range(of: "//") else { return line }
        return String(line[line.startIndex..<comment.lowerBound])
    }

    @Test("No analysis screen resolves its repository from the board's picker")
    func thePickerIsNotTheSubject() throws {
        let files = try Self.analysisSources()

        // A negative needs its positive witness: an empty file set, or a
        // renamed panel, would make every claim below vacuously true and this
        // suite would go green having read nothing.
        #expect(!files.isEmpty, "found no Analysis*.swift under Sources/ElliotAppKit")
        #expect(
            files.contains { $0.name == "AnalysisPanelView.swift" },
            """
            AnalysisPanelView.swift was not among \(files.map(\.name)) — this gate is reading the \
            wrong directory, or the panel has been renamed and the guard has silently stopped \
            covering it
            """
        )

        for file in files {
            let offenders = file.source
                .components(separatedBy: "\n")
                .enumerated()
                .filter { Self.code($0.element).contains("selectedRepoID") }
                .map { "\(file.name):\($0.offset + 1): \($0.element.trimmingCharacters(in: .whitespaces))" }

            #expect(
                offenders.isEmpty,
                """
                an analysis screen is asking the board's toolbar picker which repository it is \
                about. That is what the reader is filtering the columns by; it says nothing about \
                which repository the open analysis read, and it can move while the panel is on \
                screen. The subject belongs to AnalysisSession.repoID — read AppModel.analysisRepo \
                or AppModel.analysisRepoID instead (#213). Sites: \(offenders.joined(separator: " · "))
                """
            )
        }
    }
}
