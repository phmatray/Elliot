import Foundation

/// (universe + measurement + exemptions + clock) → (verdicts, card seeds).
///
/// Pure: no I/O, no `Date()`, no randomness. `now` is a parameter because an
/// exemption expires and an observation goes stale, and both are decisions a
/// test has to be able to drive to a chosen instant.
public enum StandardsEngine {

    public static func verdict(
        for standard: Standard,
        repo: Reading<GHRepoSummary>,
        measurement: RepoMeasurement,
        exemptions: Reading<StandardsFile>,
        now: Date,
        freshness: FreshnessPolicy
    ) -> StandardVerdict {
        // 0. The universe. It is an observation like everything else — left bare
        //    it decides scope from a listing nobody checked the age of, and a
        //    stale listing produces a perfect green on an amputated denominator.
        let summary: GHRepoSummary
        switch repo.value(freshAt: now, policy: freshness) {
        case .failure(.stale(let age)): return .unmeasured(.universeStale(age: age))
        case .failure(let why): return .unmeasured(why)
        case .success(let value): summary = value
        }

        // 1. Scope. A fork is a fork whatever else is true, and an out-of-scope
        //    repository must never reach a predicate that could file into it.
        if case .notApplicable(let why) = standard.applicability(to: summary) {
            return .notApplicable(why)
        }

        // 2. Exemptions — but an unreadable file is `unmeasured`, never "none".
        switch exemptions.value(freshAt: now, policy: freshness) {
        case .failure(let why):
            return .unmeasured(why)
        case .success(let file):
            if let e = file.exemptions.first(where: { $0.standard == standard && $0.isActive(at: now) }) {
                return .exempt(e)
            }
        }

        // 3. Only now the measurement.
        return StandardPredicates.evaluate(
            standard, repo: summary, measurement: measurement,
            now: now, freshness: freshness)
    }

    /// Every axis, for one repository, under one clock reading.
    ///
    /// `seeds` is always empty here: the card a violation deserves needs an
    /// `epoch` (task 10's `cardSeed`) that this function has no honest source
    /// for — `assess` gathers verdicts, it does not decide when an axis last
    /// turned violating. Filling it in is the next task's job, not a guess
    /// made here.
    public static func assess(
        repo: Reading<GHRepoSummary>,
        measurement: RepoMeasurement,
        exemptions: Reading<StandardsFile>,
        now: Date,
        freshness: FreshnessPolicy = .default
    ) -> RepoStandardsAssessment {
        let nameWithOwner: String
        switch repo.value(freshAt: now, policy: freshness) {
        case .success(let summary): nameWithOwner = summary.nameWithOwner
        case .failure: nameWithOwner = ""
        }

        // Step 0 above reads `repo` unconditionally before anything else, so its
        // provenance is the one observation every finding, whichever way it
        // lands, actually rests on. Nothing further down (the measurement, the
        // exemptions file) is consulted on every path — a fork returns before
        // `exemptions` is ever read — so claiming those here would be exactly
        // the fabrication `StandardFinding.provenances` exists to rule out.
        let provenances = [repo.provenance]

        let findings = Standard.allCases.map { standard in
            StandardFinding(
                id: "\(nameWithOwner)#\(standard.rawValue)",
                nameWithOwner: nameWithOwner,
                standard: standard,
                verdict: verdict(
                    for: standard, repo: repo, measurement: measurement,
                    exemptions: exemptions, now: now, freshness: freshness),
                evidence: [],
                provenances: provenances,
                assessedAt: now)
        }

        return RepoStandardsAssessment(
            nameWithOwner: nameWithOwner, findings: findings, seeds: [], assessedAt: now)
    }
}
