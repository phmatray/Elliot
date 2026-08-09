import Foundation
import Testing

@testable import ElliotModel

/// `NonBuildChecks` still says what Elliot last recorded `repo-audit` as saying.
///
/// The list is data seeded verbatim from `repo-audit/board/non_build_checks.json`.
/// Its own header names the failure mode as one-sided: a name **missing**
/// counts as a build, so a short list produces a false green on the one gate
/// that lets an unattended agent merge to a default branch. A name wrongly
/// present only refuses a merge, which a human can always make themselves.
///
/// ⛔ **What this buys, precisely.** It catches an accidental edit to the Swift
/// list — a typo, a dropped entry, a half-applied paste — on every pull request,
/// with no network and no token. It does **not** prove Elliot's copy is still
/// current against `repo-audit`'s live file, and structurally cannot:
/// `repo-audit` is a separate private repository and `ci.yml`'s `build-and-test`
/// runs with no token and no network by an argument of its own. Reaching across
/// would mean granting exactly the credential a downstream `bypassPermissions`
/// run could reach, for one JSON comparison — and would make this suite fail
/// when a *different* repository has an outage.
///
/// That residual is a human's, and it is the same discipline `repo-audit`'s own
/// header already asks for: a name is added to either copy only after being seen
/// on a real pull request.
@Suite("Non-build checks, against the vendored copy")
struct NonBuildChecksVendoredTests {

    private struct Vendored: Decodable {
        let prefixes: [String]
        let nomsExacts: [String]

        enum CodingKeys: String, CodingKey {
            case prefixes
            // The file is `repo-audit`'s, and its keys are French. Renaming them
            // in the copy would make a diff against the source unreadable, which
            // is the one thing a vendored file has to stay good at.
            case nomsExacts = "noms_exacts"
        }
    }

    private static var vendored: Vendored {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // ElliotModelTests
                .deletingLastPathComponent()   // Tests
                .deletingLastPathComponent()   // ElliotKit
                .deletingLastPathComponent()   // repo root
                .appendingPathComponent("Fixtures/non_build_checks.json")
            return try JSONDecoder().decode(Vendored.self, from: Data(contentsOf: url))
        }
    }

    /// ⚠️ Fails by **naming** the difference on each side. "The lists differ" on
    /// a list whose whole risk is one absent string is a failure message that
    /// makes you re-derive the finding by hand.
    @Test("Every exact name agrees, and the failure says which does not")
    func exactNamesAgree() throws {
        let vendored = Set(try Self.vendored.nomsExacts)
        let onlyInSwift = NonBuildChecks.exactNames.subtracting(vendored)
        let onlyInJSON = vendored.subtracting(NonBuildChecks.exactNames)
        #expect(
            onlyInSwift.isEmpty && onlyInJSON.isEmpty,
            Comment(
                rawValue:
                    "only in NonBuildChecks.swift: [\(onlyInSwift.sorted().joined(separator: ", "))] · "
                    + "only in Fixtures/non_build_checks.json: [\(onlyInJSON.sorted().joined(separator: ", "))]"
            ))
    }

    /// Order matters here in a way it does not for `exactNames`: `prefixes` is an
    /// array in both files, and a reviewer diffing the two reads them in order.
    @Test("Every prefix agrees, in the same order")
    func prefixesAgree() throws {
        let vendored = try Self.vendored.prefixes
        #expect(
            NonBuildChecks.prefixes == vendored,
            Comment(
                rawValue:
                    "NonBuildChecks.swift: \(NonBuildChecks.prefixes) · vendored: \(vendored)"))
    }

    /// A fixture that decoded to nothing would make both tests above pass
    /// against an empty expectation — the shape of an instrument that is not
    /// working reading as a result, which this repository has now been bitten by
    /// twice. So the fixture is required to be non-trivial before it is trusted.
    @Test("The fixture actually loaded")
    func theFixtureIsReal() throws {
        let vendored = try Self.vendored
        #expect(vendored.nomsExacts.isEmpty == false)
        #expect(vendored.prefixes.isEmpty == false)
    }

    /// ⛔ **`floor` is deliberately not on the list, and this pins today's
    /// answer so the day it should change, a test says so by name.**
    ///
    /// `.github/workflows/swift-floor.yml` compiles nothing since #187 — it
    /// asserts the runner's toolchain and that `ci.yml` still runs `swift test`
    /// on the same image, in 8–9 seconds. So it is not itself a build, and it is
    /// not in `exactNames`, which means a reading whose only green is `floor`
    /// counts as having a build verdict.
    ///
    /// ⚠️ That is currently unreachable, not safe by construction. `ci.yml`'s
    /// `build-and-test` carries no job-level `if:` and no `paths:` filter, and
    /// `swift-floor.yml`'s parity step already fails by name on a `paths:`
    /// filter. It does **not** catch a job-level `if:` — its own comment says
    /// grep cannot tell that from a step-level one — and closing that is #246.
    /// Until #246 lands, a job-level `if:` on `build-and-test` would leave
    /// `swift-floor` green *and* hand `isMergeableUnattended` a false green off
    /// `floor` alone.
    ///
    /// The name is not added, per the list's own rule: it has not been seen
    /// producing a false green on a real pull request. This test records the
    /// decision as data rather than leaving it to fall out of silence.
    @Test("floor alone reads as a build verdict today — the tracked gap, named")
    func floorIsNotYetListed() {
        #expect(NonBuildChecks.isInert("floor") == false)
        #expect(CIState.passing(["floor"]).hasBuildVerdict)
        // What makes that acceptable for now: a real build is the ordinary case,
        // and every inert name the list does know is still discounted beside it.
        #expect(CIState.passing(["CodeQL", "renovate/stability-days"]).hasBuildVerdict == false)
        #expect(CIState.passing(["build-and-test", "CodeQL"]).hasBuildVerdict)
    }
}
