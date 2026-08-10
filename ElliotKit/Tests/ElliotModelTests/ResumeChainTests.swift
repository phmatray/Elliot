import Foundation
import Testing

@testable import ElliotModel

private let then = Date(timeIntervalSince1970: 1_700_000_000)
private let aCard = UUID()
private let aRepo = UUID()

private func attempt(
    startedAt: Date?, createdAt: Date, resumedFrom: UUID? = nil
) -> SkillRun {
    SkillRun.card(
        cardID: aCard, repoID: aRepo, kind: .createIssue,
        prompt: "/ai-migration-kit:create-issue x", cwd: "/tmp/repo",
        resumedFrom: resumedFrom,
        startedAt: startedAt,
        logPath: "/tmp/log.ndjson", stderrPath: "/tmp/log.stderr.log",
        createdAt: createdAt
    )
}

@Suite("The start of a resume chain")
struct ResumeChainTests {

    @Test("A run that resumed nothing answers its own start")
    func aFreshRun() {
        let run = attempt(startedAt: then, createdAt: then.addingTimeInterval(-5))
        #expect(ResumeChain.firstAttemptStart(of: run, among: [run]) == then)
    }

    @Test("A run that never started falls back to when it was created")
    func neverStarted() {
        let run = attempt(startedAt: nil, createdAt: then)
        #expect(ResumeChain.firstAttemptStart(of: run, among: [run]) == then)
    }

    @Test("A chain of three answers the first attempt, not the last")
    func theWholeChain() {
        let first = attempt(startedAt: then, createdAt: then)
        let second = attempt(
            startedAt: then.addingTimeInterval(600),
            createdAt: then.addingTimeInterval(600),
            resumedFrom: first.id)
        let third = attempt(
            startedAt: then.addingTimeInterval(1_200),
            createdAt: then.addingTimeInterval(1_200),
            resumedFrom: second.id)
        #expect(ResumeChain.firstAttemptStart(of: third, among: [third, second, first]) == then)
    }

    /// The store answers a page, so a chain longer than the page loses its
    /// oldest rows. The walk stops at the oldest attempt it can see, which makes
    /// the window *later* than the truth — and later is the direction that files
    /// a second issue, so this is a case to know about rather than to hide.
    @Test("A predecessor that is not in the page stops the walk there")
    func aTruncatedPage() {
        let first = attempt(startedAt: then, createdAt: then)
        let second = attempt(
            startedAt: then.addingTimeInterval(600),
            createdAt: then.addingTimeInterval(600),
            resumedFrom: first.id)
        #expect(
            ResumeChain.firstAttemptStart(of: second, among: [second])
                == then.addingTimeInterval(600))
    }

    /// `resumedFrom` is persisted, so it can be anything a restore or a hand
    /// edit leaves behind. A cycle must terminate rather than spin the verifier.
    @Test("A cycle terminates instead of spinning")
    func aCycle() {
        var newer = attempt(
            startedAt: then.addingTimeInterval(600), createdAt: then.addingTimeInterval(600))
        var older = attempt(startedAt: then, createdAt: then)
        newer.resumedFrom = older.id
        older.resumedFrom = newer.id
        #expect(ResumeChain.firstAttemptStart(of: newer, among: [newer, older]) == then)

        var selfReferential = attempt(startedAt: then, createdAt: then)
        selfReferential.resumedFrom = selfReferential.id
        #expect(
            ResumeChain.firstAttemptStart(of: selfReferential, among: [selfReferential]) == then)
    }
}
