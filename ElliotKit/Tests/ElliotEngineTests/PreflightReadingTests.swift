import ElliotModel
import Foundation
import Testing

@testable import ElliotEngine

/// The type that replaced `PreflightService.isBlocking`.
///
/// Its whole job is that "nobody looked" cannot be spelled `[]`. `isBlocking`
/// was reached through `repoChecks[id] ?? []` at both of its call sites, so an
/// unswept repository answered `false` — the two-valued answer to a three-valued
/// question that `PreflightState` was introduced for one layer down and that the
/// screens went on giving one layer up (#302).
@Suite("Preflight reading")
struct PreflightReadingTests {

    private func check(_ id: String, _ title: String, _ status: CheckStatus) -> CheckResult {
        CheckResult(id: id, title: title, status: status, detail: "d")
    }

    /// The distinction the whole type exists for, stated as one comparison.
    @Test("An absent reading is not-checked; an empty one is a pass")
    func absentIsNotAPass() {
        #expect(PreflightReading.verdict(of: nil) == .notChecked)
        #expect(PreflightReading(results: [], checkedAt: .now).verdict == .passing)
        // And the two are genuinely different answers, which is what `isBlocking`
        // could not say: it returned `false` for both.
        #expect(PreflightState.notChecked != PreflightState.passing)
    }

    @Test("A reading with a failure blocks, and one with only warnings does not")
    func warningsDoNotBlock() {
        let warned = PreflightReading(
            results: [check("repo.clean", "Working tree", .warn), check("a", "A", .pass)],
            checkedAt: .now
        )
        #expect(warned.verdict == .passing)
        #expect(warned.blocking == nil)

        let failed = PreflightReading(
            results: [check("repo.clean", "Working tree", .warn), check("b", "B", .fail)],
            checkedAt: .now
        )
        #expect(failed.verdict == .failing)
        #expect(failed.blocking?.id == "b")
    }

    /// The card has room for one sentence, and this decides which check gets it.
    ///
    /// The service builds its checks from "is this a git repository at all"
    /// outwards, so the first failure is the one the others are most likely
    /// downstream of. Taking the last, or the alphabetically first, would name a
    /// symptom and send the reader to the wrong disclosure.
    @Test("The blocking check is the first failing one, in the order it was given")
    func theFirstFailureWins() {
        let reading = PreflightReading(
            results: [
                check("repo.exists", "Git repository", .pass),
                check("repo.isMainCheckout", "Main checkout", .fail),
                check("repo.profile", "Repo profile", .fail),
            ],
            checkedAt: .now
        )
        #expect(reading.blocking?.title == "Main checkout")
    }

    @Test("A reading carries the moment it was taken")
    func readingCarriesItsMoment() {
        let then = Date(timeIntervalSince1970: 1_754_600_000)
        #expect(PreflightReading(results: [], checkedAt: then).checkedAt == then)
    }

    /// `verdict(of:)` is the one place the absent case is folded in, so the
    /// answer for a reading that exists must be the reading's own.
    @Test("Folding an optional agrees with the reading it holds")
    func foldingAgreesWithTheReading() {
        for results in [[check("a", "A", .pass)], [check("b", "B", .fail)]] {
            let reading = PreflightReading(results: results, checkedAt: .now)
            #expect(PreflightReading.verdict(of: reading) == reading.verdict)
        }
    }
}
