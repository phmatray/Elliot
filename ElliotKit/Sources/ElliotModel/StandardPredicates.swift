import Foundation

/// The five axes' actual rules.
///
/// Each is an **arbitration**, not a translation. These rules exist today in
/// Python, in `repo-audit`, and on four of the five axes the written standard
/// and the Python disagree with each other — `topics` alone has four
/// implementations returning four different counts. The chosen answer here is
/// the *documented* rule every time; where a number moves as a result (topics
/// 21 → 38), that is by design, not a regression. See the plan's arbitration
/// table for the rejected alternatives and why each lost.
///
/// Two rules hold for every axis in this file:
/// 1. Every read of a `Reading` goes through `value(freshAt:policy:)` and
///    exits `.unmeasured` on failure. There is no `?? []` anywhere here — a
///    rate limit must never read as "no files found", which would be
///    non-compliant on every axis at once.
/// 2. A truncated tree cannot prove an absence. `RepoTree.contains` and
///    `paths(withPrefix:)` answer `nil` rather than `false` when the tree was
///    truncated, and that `nil` exits here as `.unmeasured(.treeTruncated)`,
///    never as "not found".
public enum StandardPredicates {

    public static func evaluate(
        _ standard: Standard,
        repo: GHRepoSummary,
        measurement: RepoMeasurement,
        now: Date,
        freshness: FreshnessPolicy
    ) -> (verdict: StandardVerdict, evidence: [Evidence]) {
        switch standard {
        case .editorconfig:
            return editorconfigVerdict(measurement: measurement, now: now, freshness: freshness)
        case .dependencyAutomation:
            return dependencyAutomationVerdict(measurement: measurement, now: now, freshness: freshness)
        case .ciJudgeable:
            return ciJudgeableVerdict(repo: repo, measurement: measurement, now: now, freshness: freshness)
        case .topics:
            return topicsVerdict(measurement: measurement, now: now, freshness: freshness)
        case .licence:
            return licenceVerdict(repo: repo, measurement: measurement, now: now, freshness: freshness)
        }
    }

    // MARK: - editorconfig

    /// Presence at the root only — arbitrated over reading the file's
    /// contents, which is a separate axis: `add_editorconfig.py` never
    /// overwrites, so a presence check is the only thing enforceable past the
    /// sweep's first pass.
    private static func editorconfigVerdict(
        measurement: RepoMeasurement, now: Date, freshness: FreshnessPolicy
    ) -> (verdict: StandardVerdict, evidence: [Evidence]) {
        switch measurement.tree.value(freshAt: now, policy: freshness) {
        case .failure(let why):
            return (.unmeasured(why), [])
        case .success(let tree):
            guard let present = tree.contains(".editorconfig") else {
                return (.unmeasured(.treeTruncated), [])
            }
            if present {
                return (.compliant(detail: ".editorconfig present at the root"), [])
            }
            return (
                .violating(
                    Violation(
                        summary: "No .editorconfig at the repository root",
                        expected: ".editorconfig",
                        actual: "absent",
                        fixHint: "add_editorconfig.py --only <repo> --commit")),
                [Evidence(path: ".editorconfig", exists: false)]
            )
        }
    }

    // MARK: - dependencyAutomation

    /// The six paths a Renovate or Dependabot config may live at.
    /// `renovate.json` is the canonical target cited on a violation — the
    /// other five are alternatives, not additional citations.
    private static let dependencyAutomationPaths = [
        "renovate.json", ".github/renovate.json", ".renovaterc.json", ".renovaterc",
        ".github/dependabot.yml", ".github/dependabot.yaml",
    ]

    /// Arbitrated as presence-of-config over byte-equality against the
    /// preset: re-encoding a preset with `JSONEncoder` would flip 199 of 202
    /// repositories on `\/`-escaping alone, and judging content is the
    /// sweep's job, not this axis's.
    private static func dependencyAutomationVerdict(
        measurement: RepoMeasurement, now: Date, freshness: FreshnessPolicy
    ) -> (verdict: StandardVerdict, evidence: [Evidence]) {
        switch measurement.tree.value(freshAt: now, policy: freshness) {
        case .failure(let why):
            return (.unmeasured(why), [])
        case .success(let tree):
            // The tree's `truncated` flag is one fact for the whole listing, so a
            // miss on any candidate while truncated means every other miss is
            // unknown too — but a HIT anywhere is definite regardless, so it is
            // checked first and short-circuits immediately.
            var sawUnknownMiss = false
            for path in dependencyAutomationPaths {
                guard let found = tree.contains(path) else {
                    sawUnknownMiss = true
                    continue
                }
                if found {
                    return (.compliant(detail: "\(path) present"), [])
                }
            }
            if sawUnknownMiss {
                return (.unmeasured(.treeTruncated), [])
            }
            return (
                .violating(
                    Violation(
                        summary: "No dependency-automation config found",
                        expected: "renovate.json (or one of its siblings) or a dependabot config",
                        actual: "none of the six candidate paths are present",
                        fixHint: "renovate_v2.py deploy --only <repo> --commit")),
                [Evidence(path: "renovate.json", exists: false)]
            )
        }
    }

    // MARK: - ciJudgeable

    /// At least one workflow whose `on:` has `pull_request` with no branch
    /// filter, or a filter matching the repository's own default branch —
    /// arbitrated over "a green is a build", which is a different question
    /// belonging with `GHMergeStatus`.
    ///
    /// A workflow whose `on:` block cannot be located contributes `nil` and
    /// is neither a live nor a dead vote; a repository whose every workflow
    /// contributes `nil` cannot be told apart from one with no CI at all, so
    /// it is `.unmeasured`, never `.violating`.
    private static func ciJudgeableVerdict(
        repo: GHRepoSummary, measurement: RepoMeasurement, now: Date, freshness: FreshnessPolicy
    ) -> (verdict: StandardVerdict, evidence: [Evidence]) {
        switch measurement.workflows.value(freshAt: now, policy: freshness) {
        case .failure(let why):
            return (.unmeasured(why), [])
        case .success(let workflows):
            if workflows.isEmpty {
                return (
                    .violating(
                        Violation(
                            summary: "No workflow in the repository",
                            expected: "a workflow triggering on pull_request toward \(repo.defaultBranch)",
                            actual: "no workflows at all",
                            fixHint: nil)),
                    []
                )
            }

            var anyLive = false
            var anyDead = false
            for (_, text) in workflows {
                let live = workflowIsLive(text, defaultBranch: repo.defaultBranch)
                if live == true { anyLive = true }
                if live == false { anyDead = true }
            }

            if anyLive {
                return (
                    .compliant(
                        detail: "a workflow triggers on pull requests toward \(repo.defaultBranch)"), []
                )
            }
            if anyDead {
                let evidence = workflows.keys.sorted().map { Evidence(path: $0, exists: true) }
                return (
                    .violating(
                        Violation(
                            summary: "No workflow triggers on a pull request toward \(repo.defaultBranch)",
                            expected: "pull_request unfiltered, or filtered to include \(repo.defaultBranch)",
                            actual: "filtered away from \(repo.defaultBranch), or no pull_request trigger",
                            fixHint: nil)),
                    evidence
                )
            }
            // Every workflow's `on:` block was unreadable by this scanner — not
            // the same fact as "no live workflow", so this must not read as a
            // violation nobody could actually see.
            return (
                .unmeasured(.requestFailed("no workflow's on: trigger could be located")), []
            )
        }
    }

    /// One line of a workflow file, comment stripped, indentation measured.
    /// Blank/comment-only lines are dropped at parse time so every remaining
    /// line carries content, which keeps the indentation-based scanning below
    /// from having to skip them.
    private struct ScanLine {
        let indent: Int
        let text: String
    }

    private static func scanLines(_ yaml: String) -> [ScanLine] {
        yaml.components(separatedBy: .newlines).compactMap { raw in
            let noComment = stripComment(raw)
            let indent = noComment.prefix { $0 == " " }.count
            let text = noComment.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : ScanLine(indent: indent, text: text)
        }
    }

    private static func stripComment(_ line: String) -> String {
        guard let hash = line.firstIndex(of: "#") else { return line }
        return String(line[..<hash])
    }

    /// Every line strictly more indented than the line at `index`, up to (but
    /// excluding) the next line back at or below that indentation — the
    /// line's YAML block children, one level deep.
    private static func children(of lines: [ScanLine], at index: Int) -> [ScanLine] {
        let indent = lines[index].indent
        var result: [ScanLine] = []
        var i = index + 1
        while i < lines.count, lines[i].indent > indent {
            result.append(lines[i])
            i += 1
        }
        return result
    }

    /// `key:` / `"key":` / `'key':`, plain or with a value on the same line.
    /// `nil` means the line is not this key at all; `""` means the key with
    /// nothing after it (a block follows); anything else is the same-line
    /// value, trimmed.
    private static func matchKey(_ text: String, _ key: String) -> String? {
        for spelling in ["\(key):", "\"\(key)\":", "'\(key)':"] {
            if text.hasPrefix(spelling) {
                return String(text.dropFirst(spelling.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func stripQuotes(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    private static func parseInlineList(_ raw: String) -> [String] {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("[") { s.removeFirst() }
        if s.hasSuffix("]") { s.removeLast() }
        return s.split(separator: ",")
            .map { stripQuotes($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    /// The value of a `branches:`/`branches-ignore:` key at `index`: the
    /// inline-list form on the same line, or the `- item` block form among
    /// its children.
    private static func branchList(_ lines: [ScanLine], at index: Int, key: String) -> [String] {
        let rest = matchKey(lines[index].text, key) ?? ""
        if rest.hasPrefix("[") { return parseInlineList(rest) }
        return children(of: lines, at: index)
            .filter { $0.text.hasPrefix("-") }
            .map { stripQuotes(String($0.text.dropFirst()).trimmingCharacters(in: .whitespaces)) }
    }

    /// `fnmatch`-style: `*` matches any run of characters, everything else is
    /// literal. Enough for `branches: [releases/*]`; not a general glob.
    private static func globMatches(pattern: String, value: String) -> Bool {
        if pattern == value { return true }
        guard pattern.contains("*") else { return false }
        let parts = pattern.components(separatedBy: "*")
        var remainder = Substring(value)
        for (i, part) in parts.enumerated() {
            if part.isEmpty { continue }
            if i == 0 {
                guard remainder.hasPrefix(part) else { return false }
                remainder.removeFirst(part.count)
            } else if i == parts.count - 1 {
                guard remainder.hasSuffix(part) else { return false }
                remainder.removeLast(part.count)
            } else {
                guard let range = remainder.range(of: part) else { return false }
                remainder = remainder[range.upperBound...]
            }
        }
        return true
    }

    /// Whether one workflow's `on:` trigger makes the repository judgeable on
    /// a pull request toward `defaultBranch`. `nil` means this scanner could
    /// not find the `on:` key at all — a small line scanner, not a YAML
    /// parser, so a workflow written in a shape it does not recognise must
    /// say so rather than guess.
    private static func workflowIsLive(_ yaml: String, defaultBranch: String) -> Bool? {
        let lines = scanLines(yaml)

        guard let onIndex = lines.firstIndex(where: { $0.indent == 0 && matchKey($0.text, "on") != nil })
        else { return nil }

        let onRest = matchKey(lines[onIndex].text, "on") ?? ""
        if !onRest.isEmpty {
            // Same-line value: either the inline list `on: [push, pull_request]`
            // (GitHub's shorthand accepts no filters in this form) or the scalar
            // `on: push`.
            if onRest.hasPrefix("[") {
                return parseInlineList(onRest).contains("pull_request")
            }
            return stripQuotes(onRest) == "pull_request"
        }

        // Block form: `on:` opens a nested map on the following, more-indented
        // lines.
        let onChildren = children(of: lines, at: onIndex)
        guard let prIndex = onChildren.firstIndex(where: { matchKey($0.text, "pull_request") != nil })
        else {
            // The `on:` block was found and read; it simply has no
            // `pull_request` trigger. That is a definite answer, not an
            // unreadable one.
            return false
        }

        let prRest = matchKey(onChildren[prIndex].text, "pull_request") ?? ""
        if !prRest.isEmpty {
            // A value on the same line as `pull_request:` (e.g. `{}`) — no
            // branch filter to read, so it is unfiltered.
            return true
        }

        let prChildren = children(of: onChildren, at: prIndex)
        if let branchesIndex = prChildren.firstIndex(where: { matchKey($0.text, "branches") != nil }) {
            let patterns = branchList(prChildren, at: branchesIndex, key: "branches")
            return patterns.contains { globMatches(pattern: $0, value: defaultBranch) }
        }
        if let ignoreIndex = prChildren.firstIndex(where: { matchKey($0.text, "branches-ignore") != nil })
        {
            let patterns = branchList(prChildren, at: ignoreIndex, key: "branches-ignore")
            return !patterns.contains { globMatches(pattern: $0, value: defaultBranch) }
        }
        // `pull_request:` with no branch filter at all triggers on every branch.
        return true
    }

    // MARK: - topics

    /// Too universal to sort by — present on almost every repository in the
    /// portfolio, so their presence alone says nothing about discoverability.
    private static let ubiquitousTopics: Set<String> = ["dotnet", "csharp"]

    /// Arbitrated as `topics − {dotnet, csharp}` non-empty, over "the topics
    /// list is empty" — the four existing tools disagree on that count (21 /
    /// 21 / 29 / 38) precisely because none of them applies this exclusion.
    private static func topicsVerdict(
        measurement: RepoMeasurement, now: Date, freshness: FreshnessPolicy
    ) -> (verdict: StandardVerdict, evidence: [Evidence]) {
        switch measurement.topics.value(freshAt: now, policy: freshness) {
        case .failure(let why):
            return (.unmeasured(why), [])
        case .success(let topics):
            let remaining = Set(topics).subtracting(ubiquitousTopics)
            if !remaining.isEmpty {
                return (.compliant(detail: "carries \(remaining.sorted().joined(separator: ", "))"), [])
            }
            // No file backs this axis — GitHub topics are metadata, not a path
            // in the tree — so a violation here cites nothing rather than
            // inventing one.
            return (
                .violating(
                    Violation(
                        summary: "No topic beyond dotnet/csharp",
                        expected: "at least one topic besides dotnet and csharp",
                        actual: topics.isEmpty ? "no topics" : topics.sorted().joined(separator: ", "),
                        fixHint: nil)),
                []
            )
        }
    }

    // MARK: - licence

    private static func licenceVerdict(
        repo: GHRepoSummary, measurement: RepoMeasurement, now: Date, freshness: FreshnessPolicy
    ) -> (verdict: StandardVerdict, evidence: [Evidence]) {
        switch measurement.licenceSPDX.value(freshAt: now, policy: freshness) {
        case .failure(let why):
            return (.unmeasured(why), [])
        case .success(let spdx):
            // GitHub returns an SPDX id, not a path — `LICENSE` would be a
            // guess at a filename nobody confirmed, so this axis, like
            // `topics`, cites nothing on a violation.
            switch LicencePolicy.expected(for: repo) {
            case .unlicensed:
                if spdx == nil {
                    return (.compliant(detail: "no licence, as expected"), [])
                }
                return (
                    .violating(
                        Violation(
                            summary: "A licence is present on a repository that must carry none",
                            expected: "no licence",
                            actual: spdx ?? "",
                            fixHint: "this is a commercial product; a permissive licence gives it away")),
                    []
                )
            case .spdx(let expected):
                if spdx == expected {
                    return (.compliant(detail: "licensed \(expected)"), [])
                }
                return (
                    .violating(
                        Violation(
                            summary: "Licence does not match what this repository should carry",
                            expected: expected,
                            actual: spdx ?? "none",
                            fixHint: nil)),
                    []
                )
            }
        }
    }
}

/// What licence a repository should carry, arrived at by a fixed order — the
/// order **is** the rule, the way `Standard.applicability` already states for
/// scope: the Python's three licence predicates fight over the same
/// repository and the answer depends on which runs first.
///
/// ⛔ Deliberately carries no name heuristic. `license_proposal.py`'s
/// `SKIP_EXACT`/`SKIP_SUBSTR`/`SKIP_RE` match on repository *names*
/// (`-backup`, `template`, `support`, `vault`, `-docs`, and eight literal
/// substrings) to mean "no OSS licence fits" — porting that list would repeat
/// the `metaRepositoryNames`/`AAA` defect one axis over, where a name list
/// imported from the Python silently drops a real project. A repository that
/// should stay unlicensed for a reason a name cannot carry says so in its own
/// `.elliot/standards.yml`, with a written reason — that is what exemptions
/// are for.
enum LicencePolicy {
    static func expected(for repo: GHRepoSummary) -> LicenceExpectation {
        // 1. Meta-repository: infrastructure such as `<owner>/.github`, not a
        //    project anyone ships. `StandardsEngine` already turns this
        //    repository away at the scope step for every axis, so this branch
        //    is a defensive restatement of the same fact for a caller that
        //    reaches this policy directly.
        if Standard.metaRepositoryNames.contains(repo.name) { return .unlicensed }

        // 2. Company-private: a commercial product. A permissive licence here
        //    gives the product away, and it is not retractable from anyone who
        //    already has it — the one irreversible mistake this axis guards
        //    against.
        if owner(of: repo) == "Atypical-Consulting" && repo.repoVisibility == .private {
            return .unlicensed
        }

        // 3. The written papers: TeX/Roff sources are the portfolio's LaTeX
        //    papers, keyed on the language GitHub actually detected — not on a
        //    `latex` topic, which would give the licence to anything merely
        //    tagged that way regardless of what it contains.
        if let language = repo.primaryLanguage?.name, language == "TeX" || language == "Roff" {
            return .spdx("CC-BY-4.0")
        }

        // 4. Default: MIT for everything else.
        return .spdx("MIT")
    }

    private static func owner(of repo: GHRepoSummary) -> String {
        String(repo.nameWithOwner.split(separator: "/", maxSplits: 1).first ?? "")
    }
}

/// What licence a repository is expected to carry: none at all, or a
/// specific SPDX id.
enum LicenceExpectation: Sendable, Hashable {
    case unlicensed
    case spdx(String)
}
