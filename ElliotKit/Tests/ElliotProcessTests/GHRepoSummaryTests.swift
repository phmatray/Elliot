import ElliotModel
import Foundation
import Testing

@testable import ElliotProcess

@Suite("gh repo list decoding")
struct GHRepoSummaryTests {

    @Test("The captured payload decodes with every field the reconciler reads")
    func decodesFixture() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ElliotProcessTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // ElliotKit
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("Fixtures/gh/repo-list.json")
        let summaries = try JSONDecoder().decode([GHRepoSummary].self, from: Data(contentsOf: url))

        #expect(summaries.count == 3)
        #expect(summaries.allSatisfy { $0.nameWithOwner.contains("/") && !$0.name.contains("/") })
        #expect(summaries.contains { $0.repoVisibility == .public })
        #expect(summaries.contains { $0.repoVisibility == .private })
        #expect(summaries.contains { $0.isArchived && $0.isFork })
        #expect(summaries.allSatisfy { !$0.defaultBranch.isEmpty })
    }
}
