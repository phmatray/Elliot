import Foundation

/// (universe + measurement + exemptions + clock) → (verdicts, card seeds).
///
/// Pure: no I/O, no `Date()`, no randomness. `now` is a parameter because an
/// exemption expires and an observation goes stale, and both are decisions a
/// test has to be able to drive to a chosen instant.
public enum StandardsEngine {

    /// `provenances` on the returned outcome accumulates **incrementally, per
    /// step actually reached** — never every `Reading` in scope. Only this
    /// function knows which steps ran, so it is the only place honest enough to
    /// build the list; a caller reconstructing it from the outside (as `assess`
    /// used to) can only guess, and guessing here is exactly how a fork's
    /// never-read exemptions file would end up claimed as consulted.
    public static func verdict(
        for standard: Standard,
        repo: Reading<GHRepoSummary>,
        measurement: RepoMeasurement,
        exemptions: Reading<StandardsFile>,
        now: Date,
        freshness: FreshnessPolicy
    ) -> StandardOutcome {
        // 0. The universe. It is an observation like everything else — left bare
        //    it decides scope from a listing nobody checked the age of, and a
        //    stale listing produces a perfect green on an amputated denominator.
        //    Read unconditionally, so its provenance opens the list every path
        //    shares.
        var provenances = [repo.provenance]
        let summary: GHRepoSummary
        switch repo.value(freshAt: now, policy: freshness) {
        case .failure(.stale(let age)):
            return StandardOutcome(verdict: .unmeasured(.universeStale(age: age)), provenances: provenances)
        case .failure(let why):
            return StandardOutcome(verdict: .unmeasured(why), provenances: provenances)
        case .success(let value):
            summary = value
        }

        // 1. Scope. A fork is a fork whatever else is true, and an out-of-scope
        //    repository must never reach a predicate that could file into it —
        //    and must never claim it read the exemptions file it never opened.
        if case .notApplicable(let why) = standard.applicability(to: summary) {
            return StandardOutcome(verdict: .notApplicable(why), provenances: provenances)
        }

        // 2. Exemptions — but an unreadable file is `unmeasured`, never "none".
        //    Reached only now, so its provenance joins the list only now.
        switch exemptions.value(freshAt: now, policy: freshness) {
        case .failure(let why):
            provenances.append(exemptions.provenance)
            return StandardOutcome(verdict: .unmeasured(why), provenances: provenances)
        case .success(let file):
            provenances.append(exemptions.provenance)
            if let e = file.exemptions.first(where: { $0.standard == standard && $0.isActive(at: now) }) {
                return StandardOutcome(verdict: .exempt(e), provenances: provenances)
            }
        }

        // 3. Only now the measurement, and everything it rested on — the whole
        //    point of `evaluate` returning a `StandardOutcome` rather than a
        //    bare verdict: a finding that cites nothing cannot be judged, and
        //    `observationLag` reduces over `provenances`, so a predicate's own
        //    reads must join the list this function already started rather
        //    than replace it.
        let measured = StandardPredicates.evaluate(
            standard, repo: summary, measurement: measurement,
            now: now, freshness: freshness)
        return StandardOutcome(
            verdict: measured.verdict,
            provenances: provenances + measured.provenances,
            evidence: measured.evidence)
    }

    /// The card a verdict deserves — `nil` for all four non-violating cases.
    ///
    /// Total, and separate from `verdict`, so "only a violation files a card" is
    /// one line a grep can find rather than an early return inside a switch
    /// someone later adds a case to.
    ///
    /// `epoch` is the instant the repository last became violating on this axis
    /// (or the instant an exemption expired). It is in the key because a
    /// permanent key makes recurrence unfilable: `BoardService.createCard`
    /// returns the existing card for a known key, and a card archived in Done
    /// six months ago is what it would return.
    ///
    /// ⚠️ Nothing asserts `repo.nameWithOwner == finding.nameWithOwner`. A caller
    /// that zips a finding from one repository with a summary from another
    /// mis-keys the card, silently and irreversibly — the key is what
    /// `BoardService.createCard` deduplicates on. Pass the pair this finding was
    /// actually produced from.
    ///
    /// (`repo` supplies the identity rather than the finding for no defensive
    /// reason any more: `assess` now takes `nameWithOwner` as a parameter, so a
    /// finding's name is never the empty placeholder it used to fall back to.
    /// The two are interchangeable when the caller passes a matching pair, which
    /// is the only thing this function can be given honestly.)
    public static func cardSeed(
        for finding: StandardFinding, repo: GHRepoSummary, epoch: Date
    ) -> StandardCardSeed? {
        guard finding.verdict.producesCard, case .violating(let violation) = finding.verdict else {
            return nil
        }

        let standard = finding.standard
        let key = "standard:\(repo.nameWithOwner):\(standard.rawValue):\(epoch.timeIntervalSince1970)"

        // The command that actually established this fact: the predicate's own
        // read, appended last in `verdict()` (step 3), after the universe listing
        // and the exemptions read that precede it in `provenances`. Re-running it
        // is how the first criterion below is checked rather than merely restated.
        let verifyingCommand = finding.provenances.last?.command

        // The axis, not prose: `want` restates the expectation, `benefit` is the
        // one-clause reason the axis exists (not `rubric` — a multi-sentence
        // description of what the axis checks and what it leaves alone reads as
        // "so that The repository carries…" once `UserStory.narrative` is done
        // with it). The acceptance criteria are that expectation tied to the
        // command that verifies it, plus the sweep's own re-check — neither is
        // the `want` repeated back, which would verify nothing.
        let story = UserStory(
            role: "maintainer",
            want: violation.expected,
            benefit: standard.benefit,
            acceptanceCriteria: [
                verifyingCommand.map { "\(violation.expected) — `\($0)`" } ?? violation.expected,
                "the standards sweep reports this repository compliant on \(standard.title)",
            ])

        var lines = [
            standard.rubric,
            "",
            "Expected: \(violation.expected)",
            "Actual: \(violation.actual)",
        ]
        if let fixHint = violation.fixHint {
            lines.append("Fix: \(fixHint)")
        }
        lines.append("")
        lines.append(
            "Assessed \(finding.assessedAt.description), from readings up to "
                + "\(Self.age(finding.observationLag)) older than that.")
        lines.append("Observed by:")
        lines.append(contentsOf: finding.provenances.map { "- `\($0.command)`" })

        return StandardCardSeed(
            idempotencyKey: key,
            nameWithOwner: repo.nameWithOwner,
            standard: standard,
            title: "\(standard.title): \(violation.summary)",
            story: story,
            body: lines.joined(separator: "\n"),
            evidence: finding.evidence)
    }

    /// A plain, locale-free duration — seconds, then minutes, hours, days.
    /// Nothing parses this back, so a `DateComponentsFormatter` (and the
    /// `Locale` it would carry) buys nothing `ElliotModel` should hold; see
    /// `ShipDayLabel`'s own reason for staying locale-free.
    private static func age(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        switch seconds {
        case ..<60: return "\(seconds)s"
        case ..<3_600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3_600)h"
        default: return "\(seconds / 86_400)d"
        }
    }

    /// Every axis, for one repository, under one clock reading.
    ///
    /// `seeds` is always empty here: the card a violation deserves needs an
    /// `epoch` (task 10's `cardSeed`) that this function has no honest source
    /// for — `assess` gathers verdicts, it does not decide when an axis last
    /// turned violating. Filling it in is the next task's job, not a guess
    /// made here.
    ///
    /// **`nameWithOwner` is a parameter, not something derived from `repo`.**
    /// It used to be read out of the universe observation, falling back to `""`
    /// when that observation was `.unavailable` — which gave every finding an
    /// empty name and an id of the form `"#editorconfig"`, so findings from two
    /// unreachable repositories collided id-for-id. At 343 repositories, where
    /// rate-limit failures are routine, that is reachable rather than
    /// theoretical, and `StandardFinding` is `Identifiable`.
    ///
    /// The caller already knows the identity before it ever calls `gh` — that is
    /// how the call got scoped. An identifier should be a parameter, never a
    /// byproduct of a read that may have failed.
    public static func assess(
        nameWithOwner: String,
        repo: Reading<GHRepoSummary>,
        measurement: RepoMeasurement,
        exemptions: Reading<StandardsFile>,
        now: Date,
        freshness: FreshnessPolicy = .default
    ) -> RepoStandardsAssessment {
        let findings = Standard.allCases.map { standard -> StandardFinding in
            let outcome = verdict(
                for: standard, repo: repo, measurement: measurement,
                exemptions: exemptions, now: now, freshness: freshness)
            return StandardFinding(
                id: "\(nameWithOwner)#\(standard.rawValue)",
                nameWithOwner: nameWithOwner,
                standard: standard,
                verdict: outcome.verdict,
                evidence: outcome.evidence,
                provenances: outcome.provenances,
                assessedAt: now)
        }

        return RepoStandardsAssessment(
            nameWithOwner: nameWithOwner, findings: findings, seeds: [], assessedAt: now)
    }
}
