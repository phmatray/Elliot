import Foundation
import Testing

@testable import ElliotModel

private let then = Date(timeIntervalSince1970: 1_700_000_000)
private let probe = Provenance(command: "gh repo list", observedAt: then)

@Suite("The order a verdict is decided in")
struct StandardsEngineOrderTests {

    private func repo(fork: Bool = false) -> GHRepoSummary {
        GHRepoSummary(
            nameWithOwner: "phmatray/Foo", visibility: "PUBLIC",
            defaultBranchRef: .init(name: "dev"), isFork: fork,
            primaryLanguage: GHLanguage(name: "C#"))
    }

    private var emptyMeasurement: RepoMeasurement {
        RepoMeasurement(
            tree: .observed(RepoTree(paths: [], truncated: false), probe),
            workflows: .observed([:], probe),
            dependencyConfig: .observed(nil, probe),
            topics: .observed([], probe),
            licenceSPDX: .observed(nil, probe))
    }

    private func exemptions(_ list: [Exemption]) -> Reading<StandardsFile> {
        .observed(StandardsFile(version: 1, repo: nil, exemptions: list), probe)
    }

    /// Step 0. A stale listing renders a just-unarchived repository
    /// `notApplicable` and a just-created one as nothing at all — a perfect
    /// green on an amputated denominator. That is the defect the Python probe
    /// shipped, with 25 active repositories invisible.
    @Test("A stale universe is unmeasured, never out of scope")
    func staleUniverseIsUnmeasured() {
        let old = Provenance(command: "gh repo list", observedAt: then.addingTimeInterval(-100 * 3600))
        let v = StandardsEngine.verdict(
            for: .editorconfig, repo: .observed(repo(), old),
            measurement: emptyMeasurement, exemptions: exemptions([]),
            now: then, freshness: .default)
        // `.universeStale`, not `.stale`: the distinction is the point. A stale
        // *universe* invalidates scope for every axis at once, which is a
        // different sentence from one axis's observation having aged out.
        guard case .unmeasured(.universeStale(let age)) = v else {
            Issue.record("got \(v)"); return
        }
        #expect(age == 100 * 3600)
    }

    @Test("An unreadable universe is unmeasured")
    func unreadableUniverse() {
        let v = StandardsEngine.verdict(
            for: .editorconfig,
            repo: .unavailable(.universeUnreadable("gh exited 1"), probe),
            measurement: emptyMeasurement, exemptions: exemptions([]),
            now: then, freshness: .default)
        guard case .unmeasured(.universeUnreadable) = v else { Issue.record("got \(v)"); return }
    }

    /// Step 1. Out of scope wins over everything measurable — a fork must never
    /// reach a predicate that could file a card into it.
    @Test("Scope is decided before any measurement is read")
    func scopeBeatsMeasurement() {
        let v = StandardsEngine.verdict(
            for: .editorconfig, repo: .observed(repo(fork: true), probe),
            measurement: emptyMeasurement, exemptions: exemptions([]),
            now: then, freshness: .default)
        #expect(v == .notApplicable(.fork))
    }

    /// Step 2. And an unreadable exemptions file is unmeasured, not "no
    /// exemptions" — treating it as empty is how an excused repository gets an
    /// agent sent at it.
    @Test("An active exemption wins over a violating measurement")
    func exemptionBeatsViolation() {
        let e = Exemption(
            standard: .editorconfig, reason: "hand-maintained .NET template",
            grantedBy: "philippe", grantedAt: then, expires: nil, evidence: nil)
        let v = StandardsEngine.verdict(
            for: .editorconfig, repo: .observed(repo(), probe),
            measurement: emptyMeasurement, exemptions: exemptions([e]),
            now: then, freshness: .default)
        guard case .exempt = v else { Issue.record("got \(v)"); return }
    }

    @Test("An unreadable exemptions file is unmeasured, not empty")
    func unreadableExemptionsAreUnmeasured() {
        let v = StandardsEngine.verdict(
            for: .editorconfig, repo: .observed(repo(), probe),
            measurement: emptyMeasurement,
            exemptions: .unavailable(.exemptionsUnreadable("500"), probe),
            now: then, freshness: .default)
        guard case .unmeasured(.exemptionsUnreadable) = v else { Issue.record("got \(v)"); return }
    }

    @Test("An expired exemption does not silence the axis")
    func expiredExemptionDoesNotSilence() {
        let e = Exemption(
            standard: .editorconfig, reason: "temporary", grantedBy: "philippe",
            grantedAt: then.addingTimeInterval(-86_400),
            expires: then.addingTimeInterval(-1), evidence: nil)
        let v = StandardsEngine.verdict(
            for: .editorconfig, repo: .observed(repo(), probe),
            measurement: emptyMeasurement, exemptions: exemptions([e]),
            now: then, freshness: .default)
        guard case .violating = v else { Issue.record("got \(v)"); return }
    }

    @Test("assess returns one finding per axis, always")
    func assessCoversEveryAxis() {
        let a = StandardsEngine.assess(
            repo: .observed(repo(), probe), measurement: emptyMeasurement,
            exemptions: exemptions([]), now: then, freshness: .default)
        #expect(a.findings.count == Standard.allCases.count)
    }
}
