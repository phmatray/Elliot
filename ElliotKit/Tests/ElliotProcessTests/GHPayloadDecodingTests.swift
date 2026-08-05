import ElliotModel
import Foundation
import Testing

@testable import ElliotProcess

/// The fixtures are real `gh` output, captured with the **exact** `--json` field
/// sets `GHClient` sends, so a drift between client and fixture shows up here as
/// a decode failure rather than as a silent `nil` in production.
///
/// The rows are a subset of that capture — six issues rather than every issue —
/// chosen to carry the cases these tests assert: open and closed, a body worth
/// reading, issues paired with a merged pull request and with a draft one, and
/// one issue no pull request claims. Each row is verbatim; the same shape as
/// `repo-list.json`, which stands in for a whole account with three.
@Suite("gh payloads decode from captured output")
struct GHPayloadDecodingTests {

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func data(_ name: String) throws -> Data {
        try Data(contentsOf: TestPaths.repoRoot.appendingPathComponent("Fixtures/gh/\(name)"))
    }

    @Test("Real `gh issue list` output decodes, body included")
    func decodesIssues() throws {
        let issues = try Self.decoder.decode([GHIssue].self, from: data("issues.json"))
        #expect(!issues.isEmpty)
        #expect(issues.allSatisfy { $0.number > 0 && !$0.title.isEmpty })
        #expect(issues.contains { $0.body?.isEmpty == false })  // the field this task adds
        #expect(issues.contains { $0.isClosed })
    }

    @Test("Real `gh pr list` output decodes")
    func decodesPullRequests() throws {
        let prs = try Self.decoder.decode([GHPullRequest].self, from: data("pull-requests.json"))
        #expect(!prs.isEmpty)
        #expect(prs.allSatisfy { !$0.headRefName.isEmpty })
        #expect(prs.contains { $0.isMerged })
    }

    /// Decoding proves the payload is readable, not that it is the payload the
    /// client asks for — an omitted field arrives as `nil` and decodes
    /// perfectly. This is the assertion that makes "client and fixture cannot
    /// drift apart silently" true rather than merely intended: `gh` returns
    /// exactly the requested keys, so the two sets must be equal.
    @Test(
        "Each fixture carries exactly the fields its client call requests",
        arguments: [
            ("issues.json", GHClient.issueListFields),
            ("pull-requests.json", GHClient.pullRequestListFields),
        ])
    func fixtureMatchesTheRequestedFieldSet(file: String, fields: String) throws {
        let rows = try #require(
            try JSONSerialization.jsonObject(with: data(file)) as? [[String: Any]])
        #expect(!rows.isEmpty)
        let requested = Set(fields.split(separator: ",").map(String.init))
        for row in rows {
            #expect(Set(row.keys) == requested)
        }
    }

    @Test("The captured issues and pull requests pair up the way the board expects")
    func fixturesGroupSensibly() throws {
        let issues = try Self.decoder.decode([GHIssue].self, from: data("issues.json"))
        let prs = try Self.decoder.decode([GHPullRequest].self, from: data("pull-requests.json"))
        let units = GitHubImporter.group(issues: issues, pullRequests: prs)
        // Every issue appears exactly once, and nothing lands in Backlog.
        #expect(units.count(where: { $0.issue != nil }) == issues.count)
        #expect(units.allSatisfy { GitHubImporter.column(for: $0) != .backlog })
    }
}
