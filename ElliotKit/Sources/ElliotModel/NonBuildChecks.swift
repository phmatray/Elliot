import Foundation

/// Check names that are published by something other than a build.
///
/// **Data, not logic.** Adding a name is one line and nothing else changes,
/// which is the shape of `repo-audit`'s `board/non_build_checks.json` — the
/// file this list is seeded from, verbatim, on 2026-08-08. That file exists
/// because this exact family of false greens was implemented twice and got it
/// wrong twice: a board reading GitHub's *aggregate* rollup announced 43
/// mergeable pull requests where 2 were mergeable, because a status published
/// by Renovate and a green from a hosted analyser both count as successes there.
///
/// ⚠️ This is **not** the judgement `GHMergeStatus.StatusCheck.isNonVerdict`
/// declines to make, and it does not overturn it. `isNonVerdict` reads GitHub's
/// own `conclusion` vocabulary — `SKIPPED`, `NEUTRAL`, `STALE` — needs no list
/// and drifts with nothing, and it still governs `CIState` and `PRSign`: a
/// CodeQL run that genuinely succeeded is still a pass on the card and in the
/// panel. This list is read by `ResolvedPRStatus.isMergeableUnattended` and by
/// nothing else, because that is the one caller allowed to merge to a default
/// branch on github.com with nobody watching.
///
/// ⚠️ The failure mode is one-sided and worth naming: a name **missing** from
/// this list counts as a build, so a short list produces a false green. A name
/// wrongly **in** it only refuses a merge, which a human can always make
/// themselves. Do not add a name without having seen the pull request it
/// appeared on — the portfolio's rule, `pr_verdict.py --census`, never intuition.
public enum NonBuildChecks {

    /// Matched exactly, case-sensitively — these are the strings GitHub renders.
    public static let exactNames: Set<String> = [
        "CodeQL",
        "Codacy Static Code Analysis",
        "lint-pr-title",
        "changes",
    ]

    /// Matched as a prefix, because these families name themselves per update
    /// or per language and cannot be enumerated.
    public static let prefixes: [String] = [
        "renovate/",
        "dependabot/",
        "Analyze (",
    ]

    /// Whether a check of this name proves nothing about whether the code builds.
    public static func isInert(_ name: String) -> Bool {
        if exactNames.contains(name) { return true }
        return prefixes.contains { name.hasPrefix($0) }
    }
}

public extension CIState {
    /// At least one check that both reached a verdict and is not an analyser.
    ///
    /// Deliberately false for every state that is not `.passing`: `.noChecks`
    /// is an absence of measurement, `.running` is a measurement that has not
    /// finished, `.failing` is a verdict against, and `.unknown` is a refusal to
    /// answer. None of the four is a build that went green.
    var hasBuildVerdict: Bool {
        guard case .passing(let names) = self else { return false }
        return names.contains { !NonBuildChecks.isInert($0) }
    }
}
