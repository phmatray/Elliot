import Foundation
import Testing

/// `README.md` carries no figure that goes stale on its own.
///
/// The line said **459 tests** while the suite ran 1167 — understating it by a
/// factor of 2.5, for a long time, because nothing had ever checked it. It is
/// the one document a stranger reads first, and it was the least accurate in the
/// repository.
///
/// ⛔ **Correcting the number is the wrong fix, and the profile's own history is
/// the argument.** `.claude/skills/repo-profile.md` carries the same figure and
/// has been corrected **ten times** — 408 while the suite ran 517, 517 while it
/// ran 788, 820 while it ran 996. Three of those corrections landed inside a
/// single pull request as `main` moved during review, and in #140 the number
/// moved four times on a branch that added *no tests at all*. Every move was
/// somebody else's work landing.
///
/// So the README states the property that is actually interesting and does not
/// decay: the suite needs no Xcode, no token and no network. The count stays in
/// the profile, which date-stamps it and warns the reader to read it as a date.
///
/// ⚠️ This gate is deliberately narrow — `N tests` / `N suites`, not "any number
/// in the README". The README carries several figures that are **records of a
/// past experiment** ("754 files in and 754 out", "measured 200 of 244 clones as
/// current while they were not"), and those do not decay: they are permanently
/// true about the run they describe. A matcher that could not tell the two apart
/// would either fail on honest prose or have to be switched off.
@Suite("The README carries no decaying count")
struct ReadmeCarriesNoCountTests {

    private static var readme: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // ElliotModelTests
                .deletingLastPathComponent()   // Tests
                .deletingLastPathComponent()   // ElliotKit
                .deletingLastPathComponent()   // repo root
                .appendingPathComponent("README.md")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    @Test("No line states a test or suite count")
    func noCountIsStated() throws {
        let offenders = try Self.readme
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .filter { _, line in
                line.contains(/[0-9]+ (tests|suites)/)
            }
            .map { index, line in "line \(index + 1): \(line.trimmingCharacters(in: .whitespaces))" }

        #expect(
            offenders.isEmpty,
            Comment(
                rawValue:
                    "README.md states a count that nothing keeps true:\n"
                    + offenders.joined(separator: "\n")
                    + "\nState what does not decay instead — the suite needs no Xcode, no tokens, "
                    + "no network — and leave the number in .claude/skills/repo-profile.md, which "
                    + "date-stamps it."))
    }

    /// The instrument, checked. A README that failed to load would make the test
    /// above pass against nothing — this repository has been bitten twice by a
    /// broken measurement reading as a clean result.
    @Test("The README actually loaded")
    func theReadmeIsReal() throws {
        let readme = try Self.readme
        #expect(readme.contains("swift test"))
        #expect(readme.count > 1_000)
    }
}
