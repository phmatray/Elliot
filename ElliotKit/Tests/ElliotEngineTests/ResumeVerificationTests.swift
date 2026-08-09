import ElliotModel
import ElliotProcess
import Foundation
import Testing

@testable import ElliotEngine

/// Duplicated rather than shared with the two end-to-end files: a private enum
/// in one test file is not visible from another, and one small repetition beats
/// a shared helper target for one constant.
private enum TestPaths {
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ElliotEngineTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // ElliotKit
        .deletingLastPathComponent()   // repo root

    static let fakeGH = repoRoot.appendingPathComponent("Scripts/fake-gh.sh").path
}

private let elliot = Repo(
    path: "/tmp/elliot-resume-window", nameWithOwner: "phmatray/Elliot", displayName: "Elliot"
)

/// A `gh issue list` payload with one issue, created `ago` seconds before now.
///
/// Written per test rather than checked in: the window under test is measured
/// against the clock, so a frozen date would make the result depend on the
/// calendar instead of on the code.
private func issuesFixture(
    title: String, number: Int, ago: TimeInterval, at directory: URL
) throws -> String {
    let created = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-ago))
    let json = """
        [
          {
            "number": \(number),
            "title": "\(title)",
            "url": "https://github.com/phmatray/Elliot/issues/\(number)",
            "state": "OPEN",
            "createdAt": "\(created)",
            "body": "Filed by the first attempt."
          }
        ]
        """
    let path = directory.appendingPathComponent("issues.json")
    try json.write(to: path, atomically: true, encoding: .utf8)
    return path.path
}

/// A real `Verifier` over a real subprocess. An empty `issues` path makes the
/// fake print `[]`, which is what `gh` returns for a repository with nothing
/// matching.
private func verifier(issues: String) -> Verifier {
    Verifier(gh: GHClient(config: ToolConfig(
        claudePath: "/usr/bin/false",
        ghPath: TestPaths.fakeGH,
        gitPath: "/usr/bin/false",
        environment: [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "FAKE_GH_ISSUES": issues,
        ]
    )))
}

/// One card and a two-link chain: a first attempt that started 40 minutes ago
/// and failed, and the resume that started now.
///
/// The resumed run's `logPath` names no file on purpose. `verifyCreateIssue`
/// reads issue URLs out of the log first and confirms each with `gh issue
/// view`; with no log there are no candidates, and the title sweep — the path
/// the window actually guards — is the one under test.
///
/// `resumedResultText` is spelt as a `ClosingRemark` on the way in, because
/// that is the only way to record a closing text since #288: `resultText` is
/// `private(set)` and `SkillRun.card(…)` takes `closing:`. `.stderr` is the
/// faithful source for it — a run that never had a turn produced no agent
/// prose, so the sentence is the CLI's.
private func chain(
    title: String, scratch: URL, resumedResultText: String? = nil
) -> (card: Card, first: SkillRun, resumed: SkillRun) {
    let now = Date()
    let card = Card(
        repoID: elliot.id, title: title,
        columnEnteredAt: now, createdAt: now, updatedAt: now
    )
    let first = SkillRun.card(
        cardID: card.id, repoID: elliot.id, kind: .createIssue,
        prompt: "/ai-migration-kit:create-issue \(title)", cwd: elliot.path,
        state: .failed,
        startedAt: now.addingTimeInterval(-2_400),
        endedAt: now.addingTimeInterval(-2_300),
        logPath: scratch.appendingPathComponent("first.ndjson").path,
        stderrPath: scratch.appendingPathComponent("first.log").path,
        createdAt: now.addingTimeInterval(-2_400)
    )
    let resumed = SkillRun.card(
        cardID: card.id, repoID: elliot.id, kind: .createIssue,
        prompt: "/ai-migration-kit:create-issue \(title)", cwd: elliot.path,
        resumedFrom: first.id,
        state: .failed,
        startedAt: now,
        logPath: scratch.appendingPathComponent("no-such-log.ndjson").path,
        stderrPath: scratch.appendingPathComponent("no-such-log.log").path,
        closing: resumedResultText.map { ClosingRemark(text: $0, source: .stderr) },
        createdAt: now
    )
    return (card, first, resumed)
}

private func makeScratch() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("elliot-resume-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("The create-issue window of a resumed run")
struct ResumeVerificationTests {

    /// The defect PR3 must not ship without fixing, stated as its consequence:
    /// a resumed run whose first attempt already filed the issue has to come
    /// back `.issueCreated`, because `.noIssueCreated` is precisely what makes
    /// an unattended loop file a second one on github.com.
    @Test("An issue filed by the first attempt is still found after a resume")
    func firstAttemptsIssueIsInsideTheWindow() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let title = "Stream the run log inside the card"
        let issues = try issuesFixture(title: title, number: 4242, ago: 1_800, at: scratch)
        let (card, first, resumed) = chain(title: title, scratch: scratch)

        let outcome = await verifier(issues: issues).verify(
            run: resumed, card: card, repo: elliot,
            cardRuns: [resumed, first], resume: .ran
        )
        #expect(outcome == .issueCreated(
            number: 4242, url: "https://github.com/phmatray/Elliot/issues/4242"))
    }

    /// The control that makes the test above mean something: the same run and
    /// the same issue, with the chain unavailable, falls outside the window and
    /// reports nothing created. That is what every resumed run did before this
    /// change, and it is what files the second issue.
    @Test("Without the chain, the very same issue falls outside the window")
    func withoutTheChainTheIssueIsMissed() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let title = "Stream the run log inside the card"
        let issues = try issuesFixture(title: title, number: 4242, ago: 1_800, at: scratch)
        let (card, _, resumed) = chain(title: title, scratch: scratch)

        let outcome = await verifier(issues: issues).verify(
            run: resumed, card: card, repo: elliot, cardRuns: [], resume: .ran
        )
        #expect(outcome == .noIssueCreated(
            reason: "No issue was created. It may already be covered by an existing one."))
    }

    /// A run that could not resume never had a turn, so its closing prose is the
    /// CLI complaining about a missing transcript — not a report about the idea.
    /// Put that prose in `.noIssueCreated(reason:)` and the card says the idea
    /// was already covered, which is the one sentence an unattended loop reads
    /// as "nothing to do here".
    @Test("A run that could not resume does not say the idea was already covered")
    func sessionGoneDoesNotBorrowTheAgentsProse() async throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let title = "Stream the run log inside the card"
        let (card, first, resumed) = chain(
            title: title, scratch: scratch,
            resumedResultText: "No conversation found with session ID: 5f1b2c3d-4e5f"
        )

        // No fixture, so `gh` answers `[]` and the sweep finds nothing: the
        // reason is all that is left to say.
        let outcome = await verifier(issues: "").verify(
            run: resumed, card: card, repo: elliot,
            cardRuns: [resumed, first], resume: .sessionGone
        )
        #expect(outcome == .noIssueCreated(
            reason: "The conversation this run tried to resume no longer exists, so nothing ran."))
    }
}
