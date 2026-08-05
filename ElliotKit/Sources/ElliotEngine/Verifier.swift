import ElliotModel
import ElliotProcess
import Foundation

/// Turns a finished run into what `gh` says actually happened.
///
/// The agent's closing prose is a hint and nothing more: it is free text that
/// varies between runs, and a run can end "success" having created nothing.
/// Every fact written back to a card comes from a `--json` payload.
public struct Verifier: Sendable {
    private let gh: GHClient

    public init(gh: GHClient) {
        self.gh = gh
    }

    public func verify(run: SkillRun, card: Card, repo: Repo) async -> VerifiedOutcome {
        do {
            switch run.kind {
            case .createIssue:
                return try await verifyCreateIssue(run: run, card: card, repo: repo)
            case .implementIssue:
                return try await verifyImplementIssue(run: run, card: card, repo: repo)
            case .mergePR:
                return try await verifyMergePR(run: run, card: card, repo: repo)
            case .analyzeRepo:
                // Unreachable: analysis runs are completed by ProposalHarvester,
                // and there is nothing on GitHub to check an opinion against.
                return .unverified(reason: "An analysis has no GitHub outcome to verify.")
            }
        } catch {
            return .unverified(reason: error.localizedDescription)
        }
    }

    // MARK: - create-issue

    private func verifyCreateIssue(run: SkillRun, card: Card, repo: Repo) async throws -> VerifiedOutcome {
        let since = run.startedAt ?? run.createdAt

        // The log's issue URLs are candidates, not evidence. Confirm each.
        for number in Self.issueNumbers(inLogAt: run.logPath, repo: repo.nameWithOwner) {
            if let issue = try? await gh.issue(repo: repo.nameWithOwner, number: number),
               let created = issue.createdAt, created >= since.addingTimeInterval(-60) {
                return .issueCreated(number: issue.number, url: issue.url)
            }
        }

        // No usable candidate: sweep recent issues and match on the title.
        let recent = try await gh.issues(repo: repo.nameWithOwner, limit: 100)
            .filter { ($0.createdAt ?? .distantPast) >= since.addingTimeInterval(-60) }

        let wanted = Self.tokens(card.displayTitle.isEmpty ? card.ideaText : card.displayTitle)
        if !wanted.isEmpty {
            let scored = recent
                .map { ($0, Self.overlap(wanted, Self.tokens($0.title))) }
                .filter { $0.1 >= TextSimilarity.duplicateThreshold }
                .max { $0.1 < $1.1 }
            if let match = scored?.0 {
                return .issueCreated(number: match.number, url: match.url)
            }
        }

        // Nothing new. With a zero exit this is the duplicate-skip path, which
        // is a real success: the idea was already covered by an open issue.
        return .noIssueCreated(
            reason: run.resultText?.isEmpty == false
                ? String(run.resultText!.prefix(400))
                : "No issue was created. It may already be covered by an existing one."
        )
    }

    // MARK: - implement-issue

    private func verifyImplementIssue(run: SkillRun, card: Card, repo: Repo) async throws -> VerifiedOutcome {
        guard let issue = card.issueNumber else {
            return .unverified(reason: "The card has no issue number to match a pull request against.")
        }
        let prs = try await gh.pullRequests(repo: repo.nameWithOwner, limit: 50)
        guard let match = PRMatcher.bestMatch(among: prs, issue: issue, runStartedAt: run.startedAt) else {
            return .unverified(reason: "No pull request references issue #\(issue) yet.")
        }
        if match.isMerged { return .merged(commitSHA: nil) }
        return .prOpen(
            number: match.number,
            url: match.url,
            isDraft: match.isDraft,
            branch: match.headRefName
        )
    }

    // MARK: - merge-pr

    private func verifyMergePR(run: SkillRun, card: Card, repo: Repo) async throws -> VerifiedOutcome {
        guard let pr = card.prNumber else {
            return .unverified(reason: "The card has no pull request number.")
        }
        let status = try await gh.mergeStatus(repo: repo.nameWithOwner, number: pr)

        if status.isMerged {
            return .merged(commitSHA: status.mergeCommit?.oid)
        }
        if status.state.uppercased() == "CLOSED" {
            return .closedUnmerged
        }

        let failing = status.failingChecks
        let reason = failing.isEmpty
            ? "The pull request is still open."
            : "Checks are failing: \(failing.joined(separator: ", "))."
        return .notMerged(reason: reason)
    }

    // MARK: - Helpers

    /// Issue numbers mentioned in a run log, as candidates to confirm.
    static func issueNumbers(inLogAt path: String, repo: String) -> [Int] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let needle = "https://github.com/\(repo)/issues/"
        var numbers: [Int] = []
        var search = text[...]
        while let range = search.range(of: needle) {
            let digits = search[range.upperBound...].prefix { $0.isNumber }
            if let number = Int(digits), !numbers.contains(number) { numbers.append(number) }
            search = search[range.upperBound...]
        }
        // Most recent mention first: the closing summary is at the end.
        return numbers.reversed()
    }

    // The heuristic itself lives in ElliotModel: the proposal harvester needs
    // exactly this scoring to hint at duplicates, and one implementation is the
    // only way the two stay agreed.
    static func tokens(_ text: String) -> Set<String> { TextSimilarity.tokens(text) }

    static func overlap(_ wanted: Set<String>, _ candidate: Set<String>) -> Double {
        TextSimilarity.overlap(wanted, candidate)
    }
}
