import ElliotEngine
import Foundation
import Testing

@testable import ElliotAppKit

/// Preflight's verdict strip, and the one rule it exists to hold: a repository
/// nobody read is not a repository that passed (#302).
///
/// The same rule `RepositoriesView.countSentence` holds one screen over — any
/// owner it could not list and it counts nothing — arriving on the screen whose
/// whole job is to say what is wrong.
@Suite("Preflight summary")
struct PreflightSummaryTests {

    private func check(_ status: CheckStatus) -> CheckResult {
        CheckResult(id: UUID().uuidString, title: "t", status: status, detail: "d")
    }

    private func reading(_ statuses: [CheckStatus]) -> PreflightReading {
        PreflightReading(results: statuses.map(check), checkedAt: .now)
    }

    @Test("Everything read and everything passing is the all-clear")
    func allClear() {
        let verdict = PreflightSummary.of(
            machine: [check(.pass)], repositories: [reading([.pass, .pass])])

        #expect(verdict.headline == "Everything Elliot needs is here")
        #expect(verdict.countLine == "3 checks across this machine and 1 repository.")
        #expect(verdict.symbol == "checkmark.seal.fill")
        #expect(verdict.tint == Palette.verified)
    }

    /// The false green this whole change is about.
    @Test("An unread repository never reads as an all-clear")
    func unreadIsNeverClear() {
        let verdict = PreflightSummary.of(
            machine: [check(.pass)], repositories: [reading([.pass]), nil, nil])

        #expect(verdict.unread == 2)
        #expect(verdict.headline == "2 repositories not checked yet")
        #expect(verdict.symbol != "checkmark.seal.fill")
        #expect(verdict.tint != Palette.verified)
    }

    /// It says what it counted *and* what it did not, rather than totalling a
    /// whole nobody measured.
    @Test("The count line names its own denominator")
    func theDenominatorIsNamed() {
        let verdict = PreflightSummary.of(
            machine: [], repositories: [reading([.pass, .warn]), nil, nil])

        #expect(verdict.countLine
            == "2 checks across this machine and 1 of 3 repositories — 2 not read yet.")
        // The unread repositories contribute no checks at all: there is nothing
        // to count, which is exactly why they have to be counted as repositories.
        #expect(verdict.checks == 2)
    }

    /// Unread is its own clause, never folded into the warnings — the mistake
    /// `RepoIssue.unlisted` had to be pulled back out of on the other page.
    @Test("Unread is counted apart from warnings, and warnings still win the headline")
    func unreadIsNotAWarning() {
        let verdict = PreflightSummary.of(
            machine: [check(.warn)], repositories: [nil])

        #expect(verdict.warning == 1)
        #expect(verdict.unread == 1)
        #expect(verdict.headline == "1 warning")
        #expect(verdict.symbol == "exclamationmark.triangle.fill")
        // Still said, one line down, so the warning does not bury it.
        #expect(verdict.countLine.contains("not read yet"))
    }

    @Test("A failure outranks everything and says what it costs")
    func failureOutranks() {
        let verdict = PreflightSummary.of(
            machine: [check(.fail), check(.warn)], repositories: [nil])

        #expect(verdict.headline == "1 check failing — runs will not work")
        #expect(verdict.symbol == "xmark.seal.fill")
        #expect(verdict.tint == Palette.refused)
    }

    @Test("With no repositories at all there is nothing unread")
    func noRepositories() {
        let verdict = PreflightSummary.of(machine: [check(.pass)], repositories: [])

        #expect(verdict.unread == 0)
        #expect(verdict.headline == "Everything Elliot needs is here")
        #expect(verdict.countLine == "1 checks across this machine and 0 repositories.")
    }

    /// A sweep that is running and a sweep nobody has asked for are different
    /// facts, and only the second is something the reader can act on.
    @Test("A section being read says so, rather than calling itself unchecked")
    func checkingIsNotUnchecked() {
        #expect(PreflightSummary.unreadLine(isChecking: true) == "Checking…")
        #expect(PreflightSummary.unreadLine(isChecking: false).hasPrefix("Not checked yet"))
        #expect(
            PreflightSummary.unreadLine(isChecking: true)
                != PreflightSummary.unreadLine(isChecking: false))
    }
}
