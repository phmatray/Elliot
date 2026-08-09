import Foundation

/// A portfolio-wide rule a repository is measured against.
///
/// The axis is data, not a code path — the shape `AnalysisAngle` already uses,
/// where adding a lens is a case and a paragraph. Adding a standard is a case, a
/// rubric and a predicate.
public enum Standard: String, Codable, CaseIterable, Sendable, Hashable {
    case editorconfig
    case dependencyAutomation
    case ciJudgeable
    case topics
    case licence

    public var title: String {
        switch self {
        case .editorconfig: "Editor config"
        case .dependencyAutomation: "Dependency automation"
        case .ciJudgeable: "CI can judge a pull request"
        case .topics: "Discoverable by topic"
        case .licence: "Licence"
        }
    }

    /// One clause, written to follow the words "so that" — the reason a
    /// `UserStory`'s `benefit` exists. Kept separate from `rubric`: the rubric
    /// is a multi-sentence description of the axis, half of which is what it
    /// deliberately leaves alone, and a `benefit` built from it renders through
    /// `UserStory.narrative` as "so that The repository carries…", a capital
    /// letter mid-sentence and a scope caveat standing in for a reason. This is
    /// the short answer to "why does this axis exist" that the rubric never
    /// tries to be.
    public var benefit: String {
        switch self {
        case .editorconfig:
            "every editor applies the house conventions without anyone configuring it"
        case .dependencyAutomation:
            "dependency updates arrive as reviewable pull requests instead of piling up unseen"
        case .ciJudgeable:
            "a pull request can be judged before it is merged"
        case .topics:
            "this repository can be found again by family rather than by name"
        case .licence:
            "what others may do with this code is stated rather than assumed"
        }
    }

    /// What this axis measures, in the words that go on the card — and what it
    /// leaves alone, which is the half that keeps five axes from reporting the
    /// same list.
    public var rubric: String {
        switch self {
        case .editorconfig:
            """
            The repository carries an `.editorconfig` at its root, so an editor \
            picks up the house conventions without anyone configuring it. This \
            axis measures presence only: it does not read the file, so it cannot \
            tell the house template from three lines someone typed. Formatting \
            opinions and the template's own contents are out of its reach.
            """
        case .dependencyAutomation:
            """
            The repository has dependency updates automated — a Renovate config \
            extending its account's shared preset, or a Dependabot config. This \
            axis measures that one is configured, not that its contents match \
            the preset byte for byte: adopting the preset is the sweep's job, \
            and judging content here would report a repository non-compliant for \
            a formatting difference.
            """
        case .ciJudgeable:
            """
            At least one live workflow triggers on a pull request towards this \
            repository's own default branch, so a PR can be judged at all. The \
            common failure is `branches: [main]` while the default branch is \
            `dev`, which makes every check report `skipped` — and a lot of \
            skipped checks is not a green. This axis does not ask whether the \
            build passes, nor whether a green came from a build rather than an \
            analyser: that is about one pull request, not about the repository.
            """
        case .topics:
            """
            The repository carries at least one GitHub topic beyond `dotnet` and \
            `csharp`, which are too universal to sort by. Topics are how a \
            repository is found again; one with none escapes every listing by \
            family. This axis does not judge which topics, nor how many.
            """
        case .licence:
            """
            The repository carries the licence its owner and nature call for: \
            MIT for personal code, CC-BY-4.0 for the written papers, and — \
            deliberately — none at all for the company's private repositories, \
            which are commercial products. A permissive licence there gives the \
            product away, so "has a licence" is a violation in that one case and \
            compliance everywhere else. This axis reads only the identifier \
            GitHub reports: it does not open the file, so the copyright holder, \
            the year and any local amendment are outside it, and it says nothing \
            about whether a dependency's licence is compatible with this one.
            """
        }
    }
}

/// Why an axis does not apply to a repository.
///
/// Its own answer rather than a `compliant` with a telling detail, for the reason
/// `RepoIssue.unlisted` gives: a verdict nobody scrolls to read must not be the
/// one hiding a decision. A fork counted compliant inflates the denominator;
/// counted violating it sends an agent into someone else's repository.
public enum NotApplicable: String, Codable, Sendable, Hashable, CaseIterable {
    case fork, archived, empty, noDefaultBranch, notCode, metaRepository
}

public enum Applicability: Sendable, Hashable {
    case applies
    case notApplicable(NotApplicable)
}

public extension Standard {
    /// `<owner>/.github`: infrastructure carrying an account's community-health
    /// files, not a project anyone ships.
    ///
    /// ⛔ Keep this to repositories that are genuinely not projects. It used to
    /// also carry `"AAA"`, inherited from the Python sweeps' `NOISE_EXACT` — but
    /// there the name means "do not rewrite its README", which is a different
    /// judgement. `phmatray/AAA` is an active .NET library (a fluent
    /// Arrange-Act-Assert test builder) and belongs under every axis. Excluding a
    /// real project here drops it from all five silently and records the reason
    /// nowhere; `.elliot/standards.yml` exemptions exist for that, and they
    /// demand a reason.
    static let metaRepositoryNames: Set<String> = [".github"]

    /// Scope, decided in code and in a fixed order.
    ///
    /// The order **is** the rule. The Python licence axis has three predicates
    /// fighting over the same repository and the answer depends on which runs
    /// first; writing the order down here is what stops that happening again.
    func applicability(to repo: GHRepoSummary) -> Applicability {
        if let why = RepoIssue.OutOfScope.of(repo) {
            switch why {
            case .fork: return .notApplicable(.fork)
            case .archived: return .notApplicable(.archived)
            case .empty: return .notApplicable(.empty)
            // A fact about local tree layout, not about the repository itself —
            // this function only ever sees a `GHRepoSummary`, so it falls
            // through to the later, repository-only gates instead of judging it.
            case .otherRoot: break
            }
        }
        if repo.defaultBranchRef == nil { return .notApplicable(.noDefaultBranch) }
        if Standard.metaRepositoryNames.contains(repo.name) { return .notApplicable(.metaRepository) }

        switch self {
        case .editorconfig, .dependencyAutomation, .ciJudgeable:
            return repo.isCode ? .applies : .notApplicable(.notCode)
        case .topics, .licence:
            return .applies
        }
    }
}
