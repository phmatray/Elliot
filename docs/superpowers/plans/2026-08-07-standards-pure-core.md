# Standards, plan 1 of 4 — the pure core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the pure half of the standards subsystem — every type and every
rule that decides whether a repository conforms to a portfolio axis — in
`ElliotModel`, with no I/O, no clock and no network, fully pinned by `swift test`.

**Architecture:** A collector (plan 2) gathers facts from `gh` into a
`RepoMeasurement`; `StandardsEngine.assess` turns *(universe observation +
measurement + exemptions + clock)* into a `RepoStandardsAssessment`. Everything in
this plan is that second half. It follows `RuleEngine.evaluateMove`'s precedent:
pure, total, and the single place a transition is decided.

**Tech Stack:** Swift 6.1 tools-version, `swiftLanguageModes: [.v6]`, macOS 15+,
swift-testing (`import Testing`, `@Suite`, `@Test`, `#expect`). `ElliotModel` has
**no package dependencies** and must keep none.

## Global Constraints

- `ElliotModel` has no dependencies. No Yams, no third-party YAML. The exemptions
  parser is hand-written over a strict subset — the `IssueMarkdownParser`
  precedent.
- Every type crossing an isolation boundary is `Sendable`. Strict concurrency is on.
- No `Date()`, no randomness, no `FileManager` anywhere in this plan. `now` is a
  parameter.
- **Never run `swift format` over the tree.** Format the lines you write by hand
  to match their neighbours: 4 spaces, 110 columns.
- `swift test --filter` matches the **type** name, not the `@Suite` display name.
  A filter matching nothing prints a warning and **exits 0** — check the test
  count, not the exit code.
- If a build failure looks impossible (an enum literal reported as a different
  case, a link error for a signature you can see), `rm -rf ElliotKit/.build`
  before believing it.
- Conventional Commits with the layer as scope: `feat(model): …`.
- Source of truth for every rule: `docs/superpowers/specs/2026-08-07-standards-design.md`.

## Files

| File | Responsibility |
|---|---|
| `Sources/ElliotModel/Reading.swift` | `Provenance`, `Unmeasured`, `Reading`, `FreshnessPolicy` — a fact, or the named reason there isn't one |
| `Sources/ElliotModel/GHPayloads.swift` *(modify)* | `GHRepoSummary` gains `primaryLanguage`, `isEmpty`, `isCode` |
| `Sources/ElliotModel/RepoReconciliation.swift` *(modify)* | `RepoIssue.OutOfScope.of(_:)` — the shared fork/archived judgement |
| `Sources/ElliotModel/Standard.swift` | the axes as data, and applicability |
| `Sources/ElliotModel/RepoMeasurement.swift` | `RepoTree` (three-valued), `RepoMeasurement` |
| `Sources/ElliotModel/StandardsFile.swift` | `Exemption`, `StandardsFile`, `StandardsFileParser` |
| `Sources/ElliotModel/StandardVerdict.swift` | `Violation`, `StandardVerdict`, `StandardFinding`, `RepoStandardsAssessment`, `StandardCardSeed` |
| `Sources/ElliotModel/StandardsEngine.swift` | `assess`, `verdict`, `cardSeed` — the decision order |
| `Sources/ElliotModel/StandardPredicates.swift` | the five axis predicates, one function each |

Tests mirror these one-for-one under `Tests/ElliotModelTests/`.

**Out of scope for this plan** (each gets its own): plan 2 — `GHClient`
extensions, `StandardsService`, migration v9, store queries, `fake-gh.sh`;
plan 3 — `ProposalOrigin`, auto-accept, the Standards view; plan 4 — the parity
harness.

---

### Task 1: The freshness apparatus

Nothing else can be written first: every later type holds a `Reading`.

⛔ **The type is `Reading`, not `Observation`, and renaming it back breaks the
app.** `Observation` is the name of Apple's framework module, which
`ElliotAppKit/AppModel.swift:9` imports for the `@Observable` macro. A type of
that name in `ElliotModel` shadows the module wherever both are visible, so the
macro expansion fails to resolve `Observation.Observable` and the app target
stops compiling — `ElliotModel` itself still builds, which is what makes the
mistake easy to repeat. Measured on this branch: the package builds with the file
removed and fails with it present.

**Files:**
- Create: `ElliotKit/Sources/ElliotModel/Reading.swift`
- Test: `ElliotKit/Tests/ElliotModelTests/ReadingTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `Provenance(command:observedAt:)`, `Unmeasured` (9 cases),
  `Reading<Value>.observed(Value, Provenance)` /
  `.unavailable(Unmeasured, Provenance)`,
  `Reading.value(freshAt:policy:) -> Result<Value, Unmeasured>`,
  `Reading.provenance`, `FreshnessPolicy(maxAge:)` / `.default`.

- [ ] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotModelTests/ReadingTests.swift`:

```swift
import Foundation
import Testing

@testable import ElliotModel

private let then = Date(timeIntervalSince1970: 1_700_000_000)
private let probe = Provenance(command: "gh repo list phmatray", observedAt: then)

@Suite("An observation carries why it is missing")
struct ReadingTests {

    @Test("A fresh observation yields its value")
    func freshYieldsValue() {
        let o = Reading<Int>.observed(7, probe)
        #expect(try? o.value(freshAt: then.addingTimeInterval(60), policy: .default).get() == 7)
    }

    /// The whole point of the type. A tool that cannot say "I do not know" says
    /// "0 missing" instead.
    @Test("An unavailable observation yields its reason, never a default")
    func unavailableYieldsReason() {
        let o = Reading<Int>.unavailable(.rateLimited, probe)
        guard case .failure(.rateLimited) = o.value(freshAt: then, policy: .default) else {
            Issue.record("expected .rateLimited"); return
        }
    }

    @Test("An observation older than the policy is stale, not fresh")
    func staleBeyondPolicy() {
        let o = Reading<Int>.observed(7, probe)
        let now = then.addingTimeInterval(25 * 3600)
        guard case .failure(.stale(let age)) = o.value(freshAt: now, policy: .default) else {
            Issue.record("expected .stale"); return
        }
        #expect(age == 25 * 3600)
    }

    @Test("Exactly at the boundary is still fresh")
    func boundaryIsFresh() {
        let o = Reading<Int>.observed(7, probe)
        let now = then.addingTimeInterval(24 * 3600)
        #expect(try? o.value(freshAt: now, policy: .default).get() == 7)
    }

    /// Both branches carry it: knowing *when* a failure happened is what lets a
    /// caller tell "the token expired an hour ago" from "it expired in July".
    @Test("Provenance survives on the failure branch too")
    func failureKeepsProvenance() {
        let o = Reading<Int>.unavailable(.notPermitted, probe)
        #expect(o.provenance.command == "gh repo list phmatray")
        #expect(o.provenance.observedAt == then)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd ElliotKit && swift test --filter ReadingTests`
Expected: FAIL — `cannot find 'Provenance' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ElliotKit/Sources/ElliotModel/Reading.swift`:

```swift
import Foundation

/// Where a fact came from and when, travelling with the fact.
///
/// `command` is the exact invocation, so a reader can re-run it rather than take
/// Elliot's word for the answer — the contract `CheckResult.command` already
/// states one layer up.
public struct Provenance: Codable, Sendable, Hashable {
    public var command: String
    public var observedAt: Date

    public init(command: String, observedAt: Date) {
        self.command = command
        self.observedAt = observedAt
    }
}

/// Why a fact is missing. Never an empty value, never a `false`.
public enum Unmeasured: Codable, Sendable, Hashable {
    case requestFailed(String)
    case rateLimited
    case notPermitted
    /// The git-trees API set `truncated`. A path absent from a truncated tree
    /// proves nothing. The Python probe pipes through `--jq .tree[].path`, which
    /// throws this flag away before anyone can read it, and then reports a false
    /// absence indistinguishable from a real one.
    case treeTruncated
    /// Measured, but too long ago to answer as of `now`.
    case stale(age: TimeInterval)
    case exemptionsUnreadable(String)
    case exemptionsMalformed(line: Int, detail: String)
    /// The repository listing itself was too old or unreadable. Distinct from
    /// the rest because it invalidates *scope*, not one axis.
    case universeStale(age: TimeInterval)
    case universeUnreadable(String)
}

/// How old an observation may be and still answer a question.
public struct FreshnessPolicy: Sendable, Hashable {
    public var maxAge: TimeInterval
    public init(maxAge: TimeInterval) { self.maxAge = maxAge }
    public static let `default` = FreshnessPolicy(maxAge: 24 * 3600)
}

/// A fact, or the named reason there isn't one — and in both cases what was
/// attempted and when.
///
/// There is deliberately no `valueOrDefault`, no `?? []` convenience and no
/// `Bool` accessor. `(try? …) ?? []` is the one line that turns a rate limit
/// into "no files found", which reads as non-compliant on every axis at once.
public enum Reading<Value: Codable & Sendable & Hashable>: Codable, Sendable, Hashable {
    case observed(Value, Provenance)
    case unavailable(Unmeasured, Provenance)

    public var provenance: Provenance {
        switch self {
        case .observed(_, let p), .unavailable(_, let p): p
        }
    }

    public func value(freshAt now: Date, policy: FreshnessPolicy) -> Result<Value, Unmeasured> {
        switch self {
        case .unavailable(let why, _):
            return .failure(why)
        case .observed(let v, let p):
            let age = now.timeIntervalSince(p.observedAt)
            return age > policy.maxAge ? .failure(.stale(age: age)) : .success(v)
        }
    }
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `cd ElliotKit && swift test --filter ReadingTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add ElliotKit/Sources/ElliotModel/Reading.swift ElliotKit/Tests/ElliotModelTests/ReadingTests.swift
git commit -m "feat(model): carry why a fact is missing, and how old it is"
```

---

### Task 2: `GHRepoSummary` learns language and emptiness

**Files:**
- Modify: `ElliotKit/Sources/ElliotModel/GHPayloads.swift:171-195`
- Modify: `ElliotKit/Sources/ElliotProcess/GHClient.swift:73-82`
- Test: `ElliotKit/Tests/ElliotModelTests/GHPayloadsTests.swift` *(append)*
- Test: `ElliotKit/Tests/ElliotProcessTests/GHClientFieldsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `GHLanguage(name:)`, `GHRepoSummary.primaryLanguage: GHLanguage?`,
  `GHRepoSummary.isEmpty: Bool`, `GHRepoSummary.isCode: Bool`,
  `GHClient.repoListFields: [String]`.

**Why `isCode` is a plain `Bool` and not `Bool?`.** A trivalued version was
considered and rejected: `gh` genuinely returns `null` for a repository with no
detectable language, so `nil` would mislabel a *real* answer as unmeasured. The
ambiguity worth closing is a different one — a caller asking for a narrower
`--json` set, where an absent field also decodes as `nil`. That is closed by
pinning the field list in step 1 rather than by making the type guess.

- [ ] **Step 1: Write the failing tests**

Append to `ElliotKit/Tests/ElliotModelTests/GHPayloadsTests.swift`:

```swift
@Suite("A repository summary knows whether it holds code")
struct GHRepoSummaryLanguageTests {

    private func summary(_ lang: String?, isEmpty: Bool = false) -> GHRepoSummary {
        GHRepoSummary(
            nameWithOwner: "phmatray/Foo", visibility: "PUBLIC",
            primaryLanguage: lang.map { GHLanguage(name: $0) }, isEmpty: isEmpty)
    }

    @Test("A language on the allowlist is code")
    func allowlistedLanguageIsCode() {
        #expect(summary("C#").isCode)
        #expect(summary("Swift").isCode)
        #expect(summary("HTML").isCode)
    }

    /// The seven LaTeX papers are the reason this allowlist exists: they are
    /// writing, and the axes that measure code do not apply to them.
    @Test("TeX is not code")
    func texIsNotCode() {
        #expect(!summary("TeX").isCode)
        #expect(!summary(nil).isCode)
    }

    /// GitHub classifies on byte volume, not on what a repository builds:
    /// AtypWebsite is HTML, Linelo JavaScript, github-toolkit TypeScript — all
    /// three carry .csproj files. This decides SCOPE only. It must never pick a
    /// template, which is how the Python tool posted the 26-line base
    /// editorconfig onto the company's own site.
    @Test("A missing repositoryTopics-style null decodes rather than throwing")
    func nullLanguageDecodes() throws {
        let json = """
            {"nameWithOwner":"phmatray/Foo","visibility":"PUBLIC","isFork":false,
             "isArchived":false,"primaryLanguage":null,"isEmpty":false}
            """
        let decoded = try JSONDecoder().decode(GHRepoSummary.self, from: Data(json.utf8))
        #expect(decoded.primaryLanguage == nil)
        #expect(!decoded.isCode)
    }

    /// `isEmpty` must default, because every existing call site constructs a
    /// summary without it.
    @Test("An older payload without isEmpty still decodes")
    func missingIsEmptyDefaults() throws {
        let json = """
            {"nameWithOwner":"phmatray/Foo","visibility":"PUBLIC","isFork":false,"isArchived":false}
            """
        let decoded = try JSONDecoder().decode(GHRepoSummary.self, from: Data(json.utf8))
        #expect(!decoded.isEmpty)
    }
}
```

Create `ElliotKit/Tests/ElliotProcessTests/GHClientFieldsTests.swift`:

```swift
import Foundation
import Testing

@testable import ElliotProcess

/// A captured payload is only a contract while the capture and the request name
/// the same fields. A field the client stops asking for arrives as `nil`, which
/// decodes perfectly — and `isCode` would then read `false` for the entire
/// portfolio, putting three axes out of scope everywhere with no error anywhere.
@Suite("The repo-list field set is pinned")
struct GHClientFieldsTests {

    @Test("Every field the standards subsystem depends on is requested")
    func requiredFieldsArePresent() {
        for field in ["nameWithOwner", "visibility", "defaultBranchRef", "isFork",
                      "isArchived", "url", "primaryLanguage", "isEmpty"] {
            #expect(GHClient.repoListFields.contains(field), "missing \(field)")
        }
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd ElliotKit && swift test --filter GHRepoSummaryLanguageTests`
Expected: FAIL — `extra argument 'primaryLanguage' in call`.
Run: `cd ElliotKit && swift test --filter GHClientFieldsTests`
Expected: FAIL — `type 'GHClient' has no member 'repoListFields'`.

- [ ] **Step 3: Write the implementation**

In `ElliotKit/Sources/ElliotModel/GHPayloads.swift`, add above `GHRepoSummary`:

```swift
/// GitHub's primary-language classification.
public struct GHLanguage: Codable, Sendable, Hashable {
    public var name: String
    public init(name: String) { self.name = name }
}
```

Add the two stored properties to `GHRepoSummary`, **last**, the way `GHIssue.body`
was added, so every existing call site keeps compiling:

```swift
    /// `null` for a repository with no detectable code. The field is always
    /// requested — `GHClientFieldsTests` pins that — so `nil` here means
    /// "GitHub detected no language", never "nobody asked".
    public var primaryLanguage: GHLanguage?
    public var isEmpty: Bool
```

and to the initialiser, last, both defaulted:

```swift
        primaryLanguage: GHLanguage? = nil, isEmpty: Bool = false
```

with the assignments, plus an explicit decoder default so an older payload
without `isEmpty` still decodes:

```swift
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nameWithOwner = try c.decode(String.self, forKey: .nameWithOwner)
        visibility = try c.decode(String.self, forKey: .visibility)
        defaultBranchRef = try c.decodeIfPresent(GHRepoInfo.BranchRef.self, forKey: .defaultBranchRef)
        isFork = try c.decodeIfPresent(Bool.self, forKey: .isFork) ?? false
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        url = try c.decodeIfPresent(String.self, forKey: .url)
        primaryLanguage = try c.decodeIfPresent(GHLanguage.self, forKey: .primaryLanguage)
        isEmpty = try c.decodeIfPresent(Bool.self, forKey: .isEmpty) ?? false
    }
```

Then the accessor:

```swift
public extension GHRepoSummary {
    /// The languages the portfolio standard counts as code.
    ///
    /// ⚠️ GitHub classifies on byte volume, not on what a repository builds. This
    /// decides SCOPE — whether a code-only axis applies — and never which
    /// template or rule to use.
    static let codeLanguages: Set<String> = [
        "C#", "F#", "TypeScript", "JavaScript", "Rust", "Go", "Java", "Python",
        "Swift", "C", "C++", "Kotlin", "Ruby", "PHP", "HTML", "CSS",
    ]

    var isCode: Bool {
        guard let name = primaryLanguage?.name else { return false }
        return Self.codeLanguages.contains(name)
    }
}
```

In `ElliotKit/Sources/ElliotProcess/GHClient.swift`, replace the inline `--json`
list in `repos(owner:limit:)` with a named constant, mirroring `issueListFields`:

```swift
    /// The fields every caller of `repos(owner:)` gets, pinned by
    /// `GHClientFieldsTests`. Narrowing it silently changes what decodes.
    public static let repoListFields = [
        "nameWithOwner", "visibility", "defaultBranchRef", "isFork",
        "isArchived", "url", "primaryLanguage", "isEmpty",
    ]
```

and pass `Self.repoListFields.joined(separator: ",")` where the literal was.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ElliotKit && swift test --filter GHRepoSummaryLanguageTests`
Expected: PASS, 4 tests.
Run: `cd ElliotKit && swift test --filter GHClientFieldsTests`
Expected: PASS, 1 test.
Run: `cd ElliotKit && swift test`
Expected: the whole suite still passes — `GHRepoSummary` is decoded by
`RepoRegistryService` and rendered by `RepositoriesView`.

- [ ] **Step 5: Commit**

```bash
git add ElliotKit/Sources/ElliotModel/GHPayloads.swift ElliotKit/Sources/ElliotProcess/GHClient.swift ElliotKit/Tests/ElliotModelTests/GHPayloadsTests.swift ElliotKit/Tests/ElliotProcessTests/GHClientFieldsTests.swift
git commit -m "feat(model): teach a repo summary its language and emptiness"
```

---

### Task 3: One scope judgement, not two

`RepoIssue.outOfScope(.fork)` / `.archived` already exists and is already derived
from `GHRepoSummary`. A standards predicate that re-reads `isFork` for itself is
the second implementation, and the two would disagree the day one learns
`isEmpty`: the same repository would show a live **Clone** button in Repositories
and `notApplicable(.empty)` in Standards.

**Files:**
- Modify: `ElliotKit/Sources/ElliotModel/RepoReconciliation.swift:47`, `:175-183`
- Test: `ElliotKit/Tests/ElliotModelTests/RepoScopeTests.swift`

**Interfaces:**
- Consumes: `GHRepoSummary` (task 2).
- Produces: `RepoIssue.OutOfScope.of(_ repo: GHRepoSummary) -> RepoIssue.OutOfScope?`
  and a new case `RepoIssue.OutOfScope.empty`.

- [ ] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotModelTests/RepoScopeTests.swift`:

```swift
import Foundation
import Testing

@testable import ElliotModel

@Suite("Out-of-scope is decided once")
struct RepoScopeTests {

    private func summary(
        fork: Bool = false, archived: Bool = false, empty: Bool = false
    ) -> GHRepoSummary {
        GHRepoSummary(
            nameWithOwner: "phmatray/Foo", visibility: "PUBLIC",
            isFork: fork, isArchived: archived, isEmpty: empty)
    }

    @Test("An ordinary repository is in scope")
    func ordinaryIsInScope() {
        #expect(RepoIssue.OutOfScope.of(summary()) == nil)
    }

    /// Fork is checked first so a fork reports as a fork whatever else is true.
    /// An archived fork answering `.archived` would send it to the wrong sweep.
    @Test("A fork reports as a fork even when archived and empty")
    func forkWins() {
        #expect(RepoIssue.OutOfScope.of(summary(fork: true, archived: true, empty: true)) == .fork)
    }

    @Test("Archived beats empty")
    func archivedBeatsEmpty() {
        #expect(RepoIssue.OutOfScope.of(summary(archived: true, empty: true)) == .archived)
    }

    @Test("An empty repository is out of scope")
    func emptyIsOutOfScope() {
        #expect(RepoIssue.OutOfScope.of(summary(empty: true)) == .empty)
    }

    /// The reconciler must go through the same function, not keep its own
    /// ternary — that is the whole reason this exists.
    @Test("The reconciler agrees with the shared judgement")
    func reconcilerAgrees() {
        let rows = RepoReconciler.rows(
            github: [summary(fork: true)], disk: [], registered: [], layout: .portfolio)
        #expect(rows.first?.issue == .outOfScope(.fork))
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd ElliotKit && swift test --filter RepoScopeTests`
Expected: FAIL — `type 'RepoIssue.OutOfScope' has no member 'of'`.

- [ ] **Step 3: Write the implementation**

In `RepoReconciliation.swift`, extend the nested enum and add the factory:

```swift
    public enum OutOfScope: Sendable, Hashable {
        case fork, archived, empty, otherRoot

        /// The one place fork / archived / empty is decided, for every consumer.
        ///
        /// Order is the rule, not an implementation detail: a fork reports as a
        /// fork whatever else is true, because that is the answer that decides
        /// whether anything may be written into it.
        ///
        /// `otherRoot` is deliberately absent here — it is a fact about the local
        /// tree layout, not about the repository, and only the reconciler knows it.
        public static func of(_ repo: GHRepoSummary) -> OutOfScope? {
            if repo.isFork { return .fork }
            if repo.isArchived { return .archived }
            if repo.isEmpty { return .empty }
            return nil
        }
    }
```

Replace the hand-written ternary at `:175-183` so the reconciler consumes the
same function:

```swift
        if let why = RepoIssue.OutOfScope.of(remote) {
            return RepoRow(
                id: name, nameWithOwner: name, path: actual ?? repo?.path, repoID: repo?.id,
                visibility: remote.repoVisibility,
                issue: .outOfScope(why),
                detail: switch why {
                case .fork: "A fork — out of scope."
                case .archived: "Archived on GitHub — out of scope."
                case .empty: "Empty on GitHub — nothing to measure."
                case .otherRoot: "Out of scope."
                })
        }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ElliotKit && swift test --filter RepoScopeTests`
Expected: PASS, 5 tests.
Run: `cd ElliotKit && swift test --filter RepoReconcilerTests`
Expected: PASS — the existing reconciler suite is unchanged in behaviour for
fork and archived, and now also classifies empty.

- [ ] **Step 5: Commit**

```bash
git add ElliotKit/Sources/ElliotModel/RepoReconciliation.swift ElliotKit/Tests/ElliotModelTests/RepoScopeTests.swift
git commit -m "feat(model): decide out-of-scope once, for every consumer"
```

---

### Task 4: The axes, as data

**Files:**
- Create: `ElliotKit/Sources/ElliotModel/Standard.swift`
- Test: `ElliotKit/Tests/ElliotModelTests/StandardApplicabilityTests.swift`

**Interfaces:**
- Consumes: `GHRepoSummary` (task 2), `RepoIssue.OutOfScope.of` (task 3).
- Produces: `Standard` (5 cases, `String`-raw, `CaseIterable`), `Standard.title`,
  `Standard.rubric`, `NotApplicable` (6 cases), `Applicability`,
  `Standard.applicability(to:) -> Applicability`.

- [ ] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotModelTests/StandardApplicabilityTests.swift`:

```swift
import Foundation
import Testing

@testable import ElliotModel

@Suite("Which axes apply to a repository")
struct StandardApplicabilityTests {

    private func summary(
        _ name: String = "phmatray/Foo", lang: String? = "C#",
        fork: Bool = false, archived: Bool = false, empty: Bool = false,
        branch: String? = "main"
    ) -> GHRepoSummary {
        GHRepoSummary(
            nameWithOwner: name, visibility: "PUBLIC",
            defaultBranchRef: branch.map { GHRepoInfo.BranchRef(name: $0) },
            isFork: fork, isArchived: archived,
            primaryLanguage: lang.map { GHLanguage(name: $0) }, isEmpty: empty)
    }

    @Test("Every axis applies to an ordinary code repository")
    func ordinaryCodeRepo() {
        for s in Standard.allCases {
            #expect(s.applicability(to: summary()) == .applies, "\(s)")
        }
    }

    /// Forks are out of harmonisation scope, measured by `isFork` and never case
    /// by case. Today `add_editorconfig.py --commit` without `--only` would
    /// write into ten repositories and all ten are forks, because the Python
    /// requests `isFork` and never reads it.
    @Test("No axis applies to a fork")
    func forkIsOutOfScope() {
        for s in Standard.allCases {
            #expect(s.applicability(to: summary(fork: true)) == .notApplicable(.fork), "\(s)")
        }
    }

    @Test("A repository with no default branch cannot be measured")
    func noDefaultBranch() {
        #expect(Standard.topics.applicability(to: summary(branch: nil))
                == .notApplicable(.noDefaultBranch))
    }

    /// Topics and licence are about the repository as an artefact, so they apply
    /// to the seven LaTeX papers; the three code axes do not.
    @Test("A LaTeX paper is measured for topics and licence only")
    func latexPaper() {
        let paper = summary("phmatray/fire-book", lang: "TeX")
        #expect(Standard.editorconfig.applicability(to: paper) == .notApplicable(.notCode))
        #expect(Standard.dependencyAutomation.applicability(to: paper) == .notApplicable(.notCode))
        #expect(Standard.ciJudgeable.applicability(to: paper) == .notApplicable(.notCode))
        #expect(Standard.topics.applicability(to: paper) == .applies)
        #expect(Standard.licence.applicability(to: paper) == .applies)
    }

    @Test("The account's .github repository is infrastructure, not a project")
    func metaRepository() {
        #expect(Standard.licence.applicability(to: summary("phmatray/.github", lang: nil))
                == .notApplicable(.metaRepository))
    }

    /// Every rubric must say what it leaves alone as well as what it checks —
    /// without the second half five axes drift into "the repo looks tidy" and
    /// report the same list.
    @Test("Every axis has a title and a rubric")
    func everyAxisIsDescribed() {
        for s in Standard.allCases {
            #expect(!s.title.isEmpty, "\(s)")
            #expect(s.rubric.count > 80, "\(s) rubric is too thin to judge against")
        }
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd ElliotKit && swift test --filter StandardApplicabilityTests`
Expected: FAIL — `cannot find 'Standard' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ElliotKit/Sources/ElliotModel/Standard.swift`:

```swift
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
            compliance everywhere else.
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
    /// `<owner>/.github` and the profile repository: infrastructure, not projects.
    static let metaRepositoryNames: Set<String> = [".github", "AAA"]

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
```

- [ ] **Step 4: Run it to verify it passes**

Run: `cd ElliotKit && swift test --filter StandardApplicabilityTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add ElliotKit/Sources/ElliotModel/Standard.swift ElliotKit/Tests/ElliotModelTests/StandardApplicabilityTests.swift
git commit -m "feat(model): declare the five portfolio axes and their scope"
```

---

### Task 5: The measurement, and the truncated tree

**Files:**
- Create: `ElliotKit/Sources/ElliotModel/RepoMeasurement.swift`
- Test: `ElliotKit/Tests/ElliotModelTests/RepoTreeTests.swift`

**Interfaces:**
- Consumes: `Reading` (task 1).
- Produces: `RepoTree(paths:truncated:)`, `RepoTree.contains(_:) -> Bool?`,
  `RepoTree.paths(withPrefix:) -> Set<String>?`, `RepoTree.isTruncated`,
  `RepoMeasurement(tree:workflows:dependencyConfig:topics:licenceSPDX:)`.

- [ ] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotModelTests/RepoTreeTests.swift`:

```swift
import Foundation
import Testing

@testable import ElliotModel

@Suite("A git tree answers three ways")
struct RepoTreeTests {

    @Test("A path present is present")
    func present() {
        let t = RepoTree(paths: [".editorconfig"], truncated: false)
        #expect(t.contains(".editorconfig") == true)
    }

    @Test("A path absent from a complete tree is absent")
    func absentFromComplete() {
        let t = RepoTree(paths: ["README.md"], truncated: false)
        #expect(t.contains(".editorconfig") == false)
    }

    /// The case the shell pipeline threw away. A path not found in a truncated
    /// list proves nothing, and answering `false` here files a card — which on
    /// this board spends an unattended agent run.
    @Test("A path absent from a truncated tree is unknowable")
    func absentFromTruncated() {
        let t = RepoTree(paths: ["README.md"], truncated: true)
        #expect(t.contains(".editorconfig") == nil)
    }

    @Test("A path present in a truncated tree is still present")
    func presentInTruncated() {
        let t = RepoTree(paths: [".editorconfig"], truncated: true)
        #expect(t.contains(".editorconfig") == true)
    }

    /// Enumeration is where truncation actually bites: a monorepo whose cut
    /// falls before `.github/workflows/` yields an empty set, which reads as
    /// "this repository has no CI".
    @Test("Enumeration over a truncated tree refuses to answer")
    func enumerationRefusesWhenTruncated() {
        let t = RepoTree(paths: ["src/a.cs"], truncated: true)
        #expect(t.paths(withPrefix: ".github/workflows/") == nil)
    }

    @Test("Enumeration over a complete tree returns the matches")
    func enumerationOverComplete() {
        let t = RepoTree(
            paths: [".github/workflows/ci.yml", ".github/workflows/release.yml", "README.md"],
            truncated: false)
        #expect(t.paths(withPrefix: ".github/workflows/")?.count == 2)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd ElliotKit && swift test --filter RepoTreeTests`
Expected: FAIL — `cannot find 'RepoTree' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ElliotKit/Sources/ElliotModel/RepoMeasurement.swift`:

```swift
import Foundation

/// One `git/trees?recursive=1` answer, keeping the flag the shell pipeline drops.
///
/// `paths` is **private**. Every access is three-valued, because "not in the
/// list" means nothing when the list is incomplete, and the two axes that
/// enumerate rather than look up are exactly the ones a truncation would turn
/// into a false violation.
public struct RepoTree: Codable, Sendable, Hashable {
    private var storage: Set<String>
    /// GitHub's own `truncated`.
    public var isTruncated: Bool

    public init(paths: Set<String>, truncated: Bool) {
        self.storage = paths
        self.isTruncated = truncated
    }

    /// Present, absent, or unknowable.
    public func contains(_ path: String) -> Bool? {
        if storage.contains(path) { return true }
        return isTruncated ? nil : false
    }

    /// Every path under a prefix, or `nil` when the tree was truncated — an
    /// enumeration over an incomplete list is not a set.
    public func paths(withPrefix prefix: String) -> Set<String>? {
        guard !isTruncated else { return nil }
        return storage.filter { $0.hasPrefix(prefix) }
    }
}

/// Everything the collector gathered for one repository, each part carrying its
/// own age — the tree, the workflows and the topics are separate calls, and one
/// can fail while the others succeed.
public struct RepoMeasurement: Sendable, Hashable {
    public var tree: Reading<RepoTree>
    /// Workflow path → its YAML text.
    public var workflows: Reading<[String: String]>
    /// The dependency-automation config found, and its path. `nil` value means
    /// read successfully and absent — distinct from unavailable.
    public var dependencyConfig: Reading<String?>
    public var topics: Reading<[String]>
    /// SPDX id, read from `.license.spdx_id`. ⚠️ `gh repo view --json licenseInfo`
    /// omits `spdxId`; the REST payload is the source.
    public var licenceSPDX: Reading<String?>

    public init(
        tree: Reading<RepoTree>,
        workflows: Reading<[String: String]>,
        dependencyConfig: Reading<String?>,
        topics: Reading<[String]>,
        licenceSPDX: Reading<String?>
    ) {
        self.tree = tree
        self.workflows = workflows
        self.dependencyConfig = dependencyConfig
        self.topics = topics
        self.licenceSPDX = licenceSPDX
    }
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `cd ElliotKit && swift test --filter RepoTreeTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add ElliotKit/Sources/ElliotModel/RepoMeasurement.swift ElliotKit/Tests/ElliotModelTests/RepoTreeTests.swift
git commit -m "feat(model): keep the truncated flag a git tree answer carries"
```

---

### Task 6: Exemptions, parsed strictly

**Files:**
- Create: `ElliotKit/Sources/ElliotModel/StandardsFile.swift`
- Test: `ElliotKit/Tests/ElliotModelTests/StandardsFileParserTests.swift`

**Interfaces:**
- Consumes: `Standard` (task 4), `Unmeasured` (task 1).
- Produces: `Exemption(standard:reason:grantedBy:grantedAt:expires:evidence:)`,
  `Exemption.isActive(at:)`, `StandardsFile(version:repo:exemptions:)`,
  `StandardsFile.empty`,
  `StandardsFileParser.parse(_:expecting:) -> Result<StandardsFile, Unmeasured>`.

**Subset supported**, and nothing else: `key: value`, a `-` list of mappings
under `exemptions:`, `>` folded scalars, `#` comments, two-space indentation.
Anything outside it is a refusal, not a skip — a silently skipped exemption line
becomes a violation, a violation becomes a card, and a card is an agent sent into
a repository someone deliberately excused.

- [ ] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotModelTests/StandardsFileParserTests.swift`:

```swift
import Foundation
import Testing

@testable import ElliotModel

private let now = Date(timeIntervalSince1970: 1_754_524_800)  // 2026-08-07

@Suite("The exemptions file is read strictly")
struct StandardsFileParserTests {

    private let valid = """
        # Read by Elliot's standards sweep.
        version: 1
        repo: phmatray/AtypWebsite

        exemptions:
          - standard: ciJudgeable
            reason: >
              The only workflow is a Nuke deployment that publishes the public
              site image on push to dev.
            granted_by: philippe
            granted_at: 2026-08-07
            evidence: https://github.com/phmatray/AtypWebsite/issues/61
        """

    @Test("A well-formed file parses")
    func parsesValid() throws {
        let file = try StandardsFileParser.parse(valid, expecting: "phmatray/AtypWebsite").get()
        #expect(file.version == 1)
        #expect(file.exemptions.count == 1)
        #expect(file.exemptions[0].standard == .ciJudgeable)
        #expect(file.exemptions[0].grantedBy == "philippe")
        #expect(file.exemptions[0].reason.contains("Nuke deployment"))
    }

    /// A copy-pasted file is the likeliest way an exemption lands in the wrong
    /// repository, and it would silence an axis nobody chose to silence.
    @Test("A file naming another repository is refused")
    func refusesForeignRepo() {
        guard case .failure(.exemptionsMalformed(_, let detail)) =
            StandardsFileParser.parse(valid, expecting: "phmatray/Elliot") else {
            Issue.record("expected a refusal"); return
        }
        #expect(detail.contains("AtypWebsite"))
    }

    @Test("An unknown version is refused, not parsed on a best effort")
    func refusesUnknownVersion() {
        let text = "version: 2\nexemptions: []\n"
        guard case .failure(.exemptionsMalformed) = StandardsFileParser.parse(text, expecting: nil)
        else { Issue.record("expected a refusal"); return }
    }

    @Test("An unknown standard is refused rather than skipped")
    func refusesUnknownStandard() {
        let text = """
            version: 1
            exemptions:
              - standard: quantumReadiness
                reason: because
                granted_by: philippe
                granted_at: 2026-08-07
            """
        guard case .failure(.exemptionsMalformed(let line, _)) =
            StandardsFileParser.parse(text, expecting: nil) else {
            Issue.record("expected a refusal"); return
        }
        #expect(line == 3)
    }

    @Test("An exemption with no reason is refused")
    func refusesBlankReason() {
        let text = """
            version: 1
            exemptions:
              - standard: topics
                reason: "   "
                granted_by: philippe
                granted_at: 2026-08-07
            """
        guard case .failure(.exemptionsMalformed) = StandardsFileParser.parse(text, expecting: nil)
        else { Issue.record("expected a refusal"); return }
    }

    @Test("An empty file is a file with no exemptions")
    func emptyIsValid() throws {
        let file = try StandardsFileParser.parse("version: 1\nexemptions: []\n", expecting: nil).get()
        #expect(file.exemptions.isEmpty)
    }

    @Test("An exemption without an expiry is permanent")
    func permanentExemption() throws {
        let file = try StandardsFileParser.parse(valid, expecting: nil).get()
        #expect(file.exemptions[0].isActive(at: now.addingTimeInterval(10 * 365 * 86_400)))
    }

    /// What makes an exemption a decision rather than a permanent hole.
    @Test("An expired exemption is no longer active")
    func expiredExemption() {
        let e = Exemption(
            standard: .topics, reason: "revisit after the merge", grantedBy: "philippe",
            grantedAt: now, expires: now.addingTimeInterval(86_400), evidence: nil)
        #expect(e.isActive(at: now))
        #expect(!e.isActive(at: now.addingTimeInterval(2 * 86_400)))
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd ElliotKit && swift test --filter StandardsFileParserTests`
Expected: FAIL — `cannot find 'StandardsFileParser' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ElliotKit/Sources/ElliotModel/StandardsFile.swift`. `Exemption`,
`StandardsFile` and `StandardsFile.empty` as in the spec; then the parser, whose
contract is that **every path returns either a complete file or a located
refusal** — it never returns a partially-read file:

```swift
/// Total, strict, dependency-free — the `IssueMarkdownParser` contract.
///
/// It refuses what it does not understand instead of skipping it. The failure
/// mode of a lenient parser here is an unattended `claude -p` in a repository
/// someone deliberately excused, so leniency is the expensive direction.
///
/// The supported subset is deliberately tiny: `key: value`, a `-` list of
/// mappings under `exemptions:`, `>` folded scalars, `#` comments, two-space
/// indentation. Anything else is a refusal naming its line.
public enum StandardsFileParser {
    public static func parse(
        _ text: String, expecting nameWithOwner: String?
    ) -> Result<StandardsFile, Unmeasured>
}
```

**The test suite in step 1 is the specification of behaviour** — implement
against it. These notes cover only what a test cannot express, and each one is a
trap rather than a preference:

- Scan line by line, 1-indexed, keeping the line number for every refusal.
- Strip a `#` comment only when the `#` is at line start or preceded by a space —
  a `#` inside a URL such as `…/issues/61#comment` must survive.
- `>` starts a folded scalar: consume the following lines that are indented
  deeper than the key, join with a single space, trim.
- `version` must be exactly `1`; anything else refuses with
  `"unsupported version"`.
- `repo`, when present and `nameWithOwner` is non-nil and they differ, refuses
  with a detail containing **both** names.
- Required keys per exemption: `standard`, `reason`, `granted_by`, `granted_at`.
  A missing one refuses naming the key and the line the item started on.
- `standard` must map to a `Standard` raw value; unknown refuses naming the line
  the `standard:` key was on.
- `reason` trimmed to empty refuses.
- Dates are `YYYY-MM-DD`, parsed with a `DateFormatter` pinned to
  `Locale(identifier: "en_US_POSIX")` and `TimeZone(secondsFromGMT: 0)` — a
  device locale would make a spec-conformant file fail on someone else's Mac.

- [ ] **Step 4: Run it to verify it passes**

Run: `cd ElliotKit && swift test --filter StandardsFileParserTests`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add ElliotKit/Sources/ElliotModel/StandardsFile.swift ElliotKit/Tests/ElliotModelTests/StandardsFileParserTests.swift
git commit -m "feat(model): read the exemptions file strictly, or refuse it"
```

---

### Task 7: The verdict

**Files:**
- Create: `ElliotKit/Sources/ElliotModel/StandardVerdict.swift`
- Test: `ElliotKit/Tests/ElliotModelTests/StandardVerdictTests.swift`

**Interfaces:**
- Consumes: tasks 1, 4, 6.
- Produces: `Violation(summary:expected:actual:fixHint:)`, `StandardVerdict`
  (5 cases), `.producesCard`, `.countsInDenominator`,
  `StandardFinding(id:nameWithOwner:standard:verdict:evidence:provenances:assessedAt:)`,
  `StandardFinding.observationLag`, `StandardFinding.staleness(at:)`,
  `RepoStandardsAssessment(nameWithOwner:findings:seeds:assessedAt:)`.

- [ ] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotModelTests/StandardVerdictTests.swift`:

```swift
import Foundation
import Testing

@testable import ElliotModel

private let then = Date(timeIntervalSince1970: 1_700_000_000)

@Suite("What a verdict admits")
struct StandardVerdictTests {

    private let violation = Violation(
        summary: "No .editorconfig at the root", expected: "an .editorconfig",
        actual: "absent", fixHint: nil)

    @Test("Only a violation files a card")
    func onlyViolationFilesACard() {
        #expect(StandardVerdict.violating(violation).producesCard)
        #expect(!StandardVerdict.compliant(detail: "present").producesCard)
        #expect(!StandardVerdict.notApplicable(.fork).producesCard)
        #expect(!StandardVerdict.unmeasured(.rateLimited).producesCard)
    }

    /// A ratio must never be inflated by a failure to look.
    @Test("Unmeasured and not-applicable stay out of the denominator")
    func denominatorExcludesNonMeasurements() {
        #expect(StandardVerdict.compliant(detail: "").countsInDenominator)
        #expect(StandardVerdict.violating(violation).countsInDenominator)
        #expect(!StandardVerdict.unmeasured(.rateLimited).countsInDenominator)
        #expect(!StandardVerdict.notApplicable(.fork).countsInDenominator)
    }

    /// A verdict rests on several observations of different ages. Its age is the
    /// OLDEST of them: reporting the youngest is how a verdict resting on a
    /// day-old workflow reads as two minutes fresh.
    @Test("A finding's observation lag is that of its oldest input")
    func lagIsTheOldestInput() {
        let f = StandardFinding(
            id: "phmatray/Foo#ciJudgeable", nameWithOwner: "phmatray/Foo",
            standard: .ciJudgeable, verdict: .compliant(detail: "ci.yml"),
            evidence: [],
            provenances: [
                Provenance(command: "gh api …/contents", observedAt: then.addingTimeInterval(-120)),
                Provenance(command: "gh api …/trees", observedAt: then.addingTimeInterval(-86_000)),
            ],
            assessedAt: then)
        #expect(f.observationLag == 86_000)
    }

    /// The primary key overwrites only when a new measurement lands. If
    /// measurement stops — an expired token, a repository skipped every pass —
    /// August's row survives and must not read as current in November.
    @Test("A verdict's own staleness is measured from when it was assessed")
    func stalenessFromAssessment() {
        let f = StandardFinding(
            id: "x", nameWithOwner: "phmatray/Foo", standard: .topics,
            verdict: .compliant(detail: ""), evidence: [],
            provenances: [Provenance(command: "gh", observedAt: then)], assessedAt: then)
        #expect(f.staleness(at: then.addingTimeInterval(90 * 86_400)) == 90 * 86_400)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd ElliotKit && swift test --filter StandardVerdictTests`
Expected: FAIL — `cannot find 'Violation' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ElliotKit/Sources/ElliotModel/StandardVerdict.swift` with the five-case
`StandardVerdict` from the spec, and:

```swift
public struct StandardFinding: Identifiable, Sendable, Hashable {
    public var id: String            // "phmatray/Foo#editorconfig"
    public var nameWithOwner: String
    public var standard: Standard
    public var verdict: StandardVerdict
    public var evidence: [Evidence]
    /// Every observation this verdict actually consulted.
    public var provenances: [Provenance]
    public var assessedAt: Date

    /// How stale the OLDEST input was when the predicate ran.
    public var observationLag: TimeInterval {
        guard let oldest = provenances.map(\.observedAt).min() else { return 0 }
        return assessedAt.timeIntervalSince(oldest)
    }

    /// How old this VERDICT is now — a different question, and the one a reader
    /// of a stored row is actually asking.
    public func staleness(at now: Date) -> TimeInterval {
        now.timeIntervalSince(assessedAt)
    }
}
```

> `Evidence` is reused from `StoryProposal.swift`. ⚠️ For standards,
> `Evidence.exists` means *present in the GitHub tree*, never on disk.
> `ProposalHarvester.resolve(_:repoPath:)` resolves with `FileManager` under a
> clone root and must **not** be reused here — most measured repositories have no
> clone, and every finding would come back `exists: false`, rendering a
> non-measurement as "invented".

- [ ] **Step 4: Run it to verify it passes**

Run: `cd ElliotKit && swift test --filter StandardVerdictTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add ElliotKit/Sources/ElliotModel/StandardVerdict.swift ElliotKit/Tests/ElliotModelTests/StandardVerdictTests.swift
git commit -m "feat(model): make unmeasured a first-class verdict"
```

---

### Task 8: The decision order

The predicates themselves land in task 9; this task pins the order around them,
because the order is the rule.

**Files:**
- Create: `ElliotKit/Sources/ElliotModel/StandardsEngine.swift`
- Test: `ElliotKit/Tests/ElliotModelTests/StandardsEngineOrderTests.swift`

**Interfaces:**
- Consumes: tasks 1–7.
- Produces:
  `StandardsEngine.verdict(for:repo:measurement:exemptions:now:freshness:) -> StandardVerdict`
  and `StandardsEngine.assess(repo:measurement:exemptions:now:freshness:) -> RepoStandardsAssessment`,
  where `repo` is `Reading<GHRepoSummary>`.

- [ ] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotModelTests/StandardsEngineOrderTests.swift`:

```swift
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
        guard case .unmeasured(.stale) = v else { Issue.record("got \(v)"); return }
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd ElliotKit && swift test --filter StandardsEngineOrderTests`
Expected: FAIL — `cannot find 'StandardsEngine' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ElliotKit/Sources/ElliotModel/StandardsEngine.swift`:

```swift
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

    public static func assess(
        repo: Reading<GHRepoSummary>,
        measurement: RepoMeasurement,
        exemptions: Reading<StandardsFile>,
        now: Date,
        freshness: FreshnessPolicy = .default
    ) -> RepoStandardsAssessment
}
```

For this task, `StandardPredicates.evaluate` may be a stub returning
`.violating(Violation(summary: "not yet implemented", expected: "", actual: "", fixHint: nil))`
for every axis — task 9 replaces it. The stub is what makes
`expiredExemptionDoesNotSilence` meaningful now.

- [ ] **Step 4: Run it to verify it passes**

Run: `cd ElliotKit && swift test --filter StandardsEngineOrderTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add ElliotKit/Sources/ElliotModel/StandardsEngine.swift ElliotKit/Tests/ElliotModelTests/StandardsEngineOrderTests.swift
git commit -m "feat(model): pin the order a standards verdict is decided in"
```

---

### Task 9: The five predicates

Each is an **arbitration**, not a translation: on four of five axes the written
standard and the Python disagree, and the Python disagrees with itself. The
chosen answer is the *documented* rule in every case; the alternatives and their
counts are recorded here so a moved number does not read as a regression.

**Files:**
- Create: `ElliotKit/Sources/ElliotModel/StandardPredicates.swift`
- Test: `ElliotKit/Tests/ElliotModelTests/StandardPredicatesTests.swift`

**Interfaces:**
- Consumes: tasks 1–7.
- Produces: `StandardPredicates.evaluate(_:repo:measurement:now:freshness:) -> StandardVerdict`.

| Axis | Rule implemented | Rejected alternative |
|---|---|---|
| `editorconfig` | `.editorconfig` present at the root of the tree | reading the file's contents — a separate axis, since `add_editorconfig.py` never overwrites and today's presence check is unenforceable past the first pass |
| `dependencyAutomation` | any of `renovate.json`, `.github/renovate.json`, `.renovaterc.json`, `.renovaterc`, `.github/dependabot.yml`, `.github/dependabot.yaml` | byte-equality against the preset — belongs to the sweep that writes; ⛔ and re-encoding with `JSONEncoder` would flip 199 of 202 repositories on `\/`-escaping alone |
| `ciJudgeable` | at least one workflow whose `on:` has `pull_request` with no branch filter, or a filter matching the repository's own default branch | the "a green is a build" half — different cardinality, belongs with `GHMergeStatus` |
| `topics` | `topics − {dotnet, csharp}` non-empty | "the topics list is empty" (21 / 29 depending on the tool) |
| `licence` | expected value by (owner, visibility, language), compared to the SPDX id | a boolean "has a licence" — which would put MIT on a commercial product |

- [ ] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotModelTests/StandardPredicatesTests.swift` with, at
minimum, these cases — each named for the trap it closes:

```swift
import Foundation
import Testing

@testable import ElliotModel

private let then = Date(timeIntervalSince1970: 1_700_000_000)
private let probe = Provenance(command: "gh api", observedAt: then)

@Suite("The five predicates")
struct StandardPredicatesTests {

    private func repo(
        _ name: String = "phmatray/Foo", visibility: String = "PUBLIC",
        lang: String = "C#", branch: String = "dev"
    ) -> GHRepoSummary {
        GHRepoSummary(
            nameWithOwner: name, visibility: visibility,
            defaultBranchRef: .init(name: branch),
            primaryLanguage: GHLanguage(name: lang))
    }

    private func measurement(
        tree: Reading<RepoTree> = .observed(RepoTree(paths: [], truncated: false), probe),
        workflows: Reading<[String: String]> = .observed([:], probe),
        topics: Reading<[String]> = .observed([], probe),
        licence: Reading<String?> = .observed(nil, probe)
    ) -> RepoMeasurement {
        RepoMeasurement(
            tree: tree, workflows: workflows, dependencyConfig: .observed(nil, probe),
            topics: topics, licenceSPDX: licence)
    }

    private func verdict(_ s: Standard, _ r: GHRepoSummary, _ m: RepoMeasurement) -> StandardVerdict {
        StandardPredicates.evaluate(s, repo: r, measurement: m, now: then, freshness: .default)
    }

    // MARK: editorconfig

    @Test("An .editorconfig at the root is compliant")
    func editorconfigPresent() {
        let m = measurement(tree: .observed(RepoTree(paths: [".editorconfig"], truncated: false), probe))
        guard case .compliant = verdict(.editorconfig, repo(), m) else {
            Issue.record("expected compliant"); return
        }
    }

    /// Only the root counts: `root = true` lives at the root, and a nested file
    /// does not configure the repository.
    @Test("An .editorconfig in a subdirectory does not count")
    func editorconfigNested() {
        let m = measurement(tree: .observed(RepoTree(paths: ["src/.editorconfig"], truncated: false), probe))
        guard case .violating = verdict(.editorconfig, repo(), m) else {
            Issue.record("expected violating"); return
        }
    }

    /// The truncation trap: absence from an incomplete list is not absence.
    @Test("A truncated tree cannot prove an .editorconfig is missing")
    func editorconfigTruncated() {
        let m = measurement(tree: .observed(RepoTree(paths: ["README.md"], truncated: true), probe))
        guard case .unmeasured(.treeTruncated) = verdict(.editorconfig, repo(), m) else {
            Issue.record("expected unmeasured"); return
        }
    }

    // MARK: dependencyAutomation

    @Test("Any of the four Renovate paths counts")
    func renovateAnyPath() {
        for path in ["renovate.json", ".github/renovate.json", ".renovaterc.json", ".renovaterc"] {
            let m = measurement(tree: .observed(RepoTree(paths: [path], truncated: false), probe))
            guard case .compliant = verdict(.dependencyAutomation, repo(), m) else {
                Issue.record("\(path) should count"); return
            }
        }
    }

    @Test("Dependabot counts as dependency automation")
    func dependabotCounts() {
        let m = measurement(tree: .observed(
            RepoTree(paths: [".github/dependabot.yml"], truncated: false), probe))
        guard case .compliant = verdict(.dependencyAutomation, repo(), m) else {
            Issue.record("expected compliant"); return
        }
    }

    // MARK: ciJudgeable

    @Test("A workflow triggering on any pull request is judgeable")
    func ciUnfiltered() {
        let m = measurement(workflows: .observed(
            [".github/workflows/ci.yml": "on:\n  pull_request:\njobs: {}\n"], probe))
        guard case .compliant = verdict(.ciJudgeable, repo(), m) else {
            Issue.record("expected compliant"); return
        }
    }

    /// The exact pattern the portfolio is full of: filtered to `main` while the
    /// default branch is `dev`, so every check reports `skipped`.
    @Test("A filter naming another branch leaves the repository unjudgeable")
    func ciFilteredToWrongBranch() {
        let m = measurement(workflows: .observed(
            [".github/workflows/ci.yml": "on:\n  pull_request:\n    branches: [main]\njobs: {}\n"],
            probe))
        guard case .violating = verdict(.ciJudgeable, repo(branch: "dev"), m) else {
            Issue.record("expected violating"); return
        }
    }

    @Test("A filter matching the default branch is fine")
    func ciFilteredToDefault() {
        let m = measurement(workflows: .observed(
            [".github/workflows/ci.yml": "on:\n  pull_request:\n    branches: [dev]\njobs: {}\n"],
            probe))
        guard case .compliant = verdict(.ciJudgeable, repo(branch: "dev"), m) else {
            Issue.record("expected compliant"); return
        }
    }

    /// One badly filtered workflow among several correct ones is not a failure.
    /// This is the criterion that makes the real count 9 rather than ~30.
    @Test("One live workflow is enough, however many dead ones there are")
    func ciOneLiveIsEnough() {
        let m = measurement(workflows: .observed([
            ".github/workflows/deploy.yml": "on:\n  push:\n    branches: [main]\njobs: {}\n",
            ".github/workflows/ci.yml": "on:\n  pull_request:\njobs: {}\n",
        ], probe))
        guard case .compliant = verdict(.ciJudgeable, repo(), m) else {
            Issue.record("expected compliant"); return
        }
    }

    @Test("The inline list form is understood")
    func ciInlineForm() {
        let m = measurement(workflows: .observed(
            [".github/workflows/ci.yml": "on: [push, pull_request]\njobs: {}\n"], probe))
        guard case .compliant = verdict(.ciJudgeable, repo(), m) else {
            Issue.record("expected compliant"); return
        }
    }

    // MARK: topics

    /// The arbitration: the documented rule, not any of the four implementations.
    @Test("dotnet and csharp alone are not a family topic")
    func topicsUbiquitousOnly() {
        let m = measurement(topics: .observed(["dotnet", "csharp"], probe))
        guard case .violating = verdict(.topics, repo(), m) else {
            Issue.record("expected violating"); return
        }
    }

    @Test("One topic beyond the ubiquitous pair is enough")
    func topicsFamilyPresent() {
        let m = measurement(topics: .observed(["dotnet", "blazor"], probe))
        guard case .compliant = verdict(.topics, repo(), m) else {
            Issue.record("expected compliant"); return
        }
    }

    // MARK: licence

    @Test("Personal public code expects MIT")
    func licenceMIT() {
        let m = measurement(licence: .observed("MIT", probe))
        guard case .compliant = verdict(.licence, repo(), m) else {
            Issue.record("expected compliant"); return
        }
    }

    /// The one axis where carrying a licence is the violation. A permissive
    /// licence on a commercial product gives the product away, and it is not
    /// retractable from anyone who already has it.
    @Test("A private company repository expects no licence at all")
    func licenceCompanyPrivateExpectsNone() {
        let company = repo("Atypical-Consulting/Product", visibility: "PRIVATE")
        guard case .compliant = verdict(.licence, company, measurement(licence: .observed(nil, probe)))
        else { Issue.record("expected compliant"); return }
        guard case .violating = verdict(.licence, company, measurement(licence: .observed("MIT", probe)))
        else { Issue.record("MIT on a product must violate"); return }
    }

    /// Keyed on the language, the way the code does — not on a `latex` topic,
    /// the way the prose reads. A topic-keyed port gives CC-BY-4.0 to anything
    /// tagged latex whatever it contains.
    @Test("A TeX paper expects CC-BY-4.0")
    func licenceLatexPaper() {
        let paper = repo("phmatray/fire-book", lang: "TeX")
        guard case .compliant = verdict(.licence, paper, measurement(licence: .observed("CC-BY-4.0", probe)))
        else { Issue.record("expected compliant"); return }
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd ElliotKit && swift test --filter StandardPredicatesTests`
Expected: FAIL — every case, because the task-8 stub violates unconditionally.

- [ ] **Step 3: Write the implementation**

**The 16 tests in step 1 are the specification** — implement against them. Create
`ElliotKit/Sources/ElliotModel/StandardPredicates.swift` with one private
function per axis and a single `evaluate` that dispatches. Every read of an
`Reading` goes through `value(freshAt:policy:)` and exits `.unmeasured` on
failure — there is no `?? []` anywhere in this file.

The `on:` block reader is a small line scanner, not a YAML parser, and must
handle: `on:` / `"on":` / `'on':`; the inline list `on: [push, pull_request]`;
the scalar `on: push`; the block form with `pull_request:` followed by
`branches:` or `branches-ignore:`, in inline `[a, b]` or `- a` form; and
end-of-line `#` comments. Glob matching uses `fnmatch`-style `*` so
`branches: [releases/*]` behaves. A workflow whose `on:` block cannot be located
contributes `nil`, and a repository whose every workflow contributes `nil` is
`.unmeasured`, not `.violating`.

`LicencePolicy.expected(for:)` lives in this file and is evaluated in a fixed,
commented order: meta-repository → company-private → `TeX`/`Roff` → default MIT.

- [ ] **Step 4: Run it to verify it passes**

Run: `cd ElliotKit && swift test --filter StandardPredicatesTests`
Expected: PASS, 16 tests.
Run: `cd ElliotKit && swift test`
Expected: the whole suite green. Sample it five times — one green run does not
clear a suite, and a defect failing 53 % of the time once reached `main` past 21
single-sample merges:

```bash
cd ElliotKit && for i in 1 2 3 4 5; do swift test 2>&1 | tail -3; done
```

- [ ] **Step 5: Commit**

```bash
git add ElliotKit/Sources/ElliotModel/StandardPredicates.swift ElliotKit/Tests/ElliotModelTests/StandardPredicatesTests.swift
git commit -m "feat(model): decide the five portfolio axes

Each axis is an arbitration: the prose and the Python disagree on four of
five, and the Python disagrees with itself. The documented rule wins in
every case, so topics moves from 21 to 38 by design, not by regression."
```

---

### Task 10: The card seed

**Files:**
- Modify: `ElliotKit/Sources/ElliotModel/StandardVerdict.swift`
- Modify: `ElliotKit/Sources/ElliotModel/StandardsEngine.swift`
- Test: `ElliotKit/Tests/ElliotModelTests/StandardCardSeedTests.swift`

**Interfaces:**
- Consumes: tasks 4, 7, 9.
- Produces: `StandardCardSeed(idempotencyKey:nameWithOwner:standard:title:story:body:evidence:)`,
  `StandardsEngine.cardSeed(for:repo:epoch:) -> StandardCardSeed?`.

- [ ] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotModelTests/StandardCardSeedTests.swift`:

```swift
import Foundation
import Testing

@testable import ElliotModel

private let then = Date(timeIntervalSince1970: 1_700_000_000)
private let probe = Provenance(command: "gh api", observedAt: then)

@Suite("The card a violation deserves")
struct StandardCardSeedTests {

    private func finding(_ v: StandardVerdict) -> StandardFinding {
        StandardFinding(
            id: "phmatray/Foo#editorconfig", nameWithOwner: "phmatray/Foo",
            standard: .editorconfig, verdict: v,
            evidence: [Evidence(path: ".editorconfig", line: nil, exists: false)],
            provenances: [probe], assessedAt: then)
    }

    private let repo = GHRepoSummary(
        nameWithOwner: "phmatray/Foo", visibility: "PUBLIC",
        defaultBranchRef: .init(name: "dev"), primaryLanguage: GHLanguage(name: "C#"))

    @Test("Only a violation produces a seed")
    func onlyViolationSeeds() {
        #expect(StandardsEngine.cardSeed(
            for: finding(.compliant(detail: "present")), repo: repo, epoch: then) == nil)
        #expect(StandardsEngine.cardSeed(
            for: finding(.unmeasured(.rateLimited)), repo: repo, epoch: then) == nil)
        #expect(StandardsEngine.cardSeed(
            for: finding(.notApplicable(.fork)), repo: repo, epoch: then) == nil)
        #expect(StandardsEngine.cardSeed(
            for: finding(.exempt(Exemption(
                standard: .editorconfig, reason: "hand-maintained", grantedBy: "philippe",
                grantedAt: then, expires: nil, evidence: nil))),
            repo: repo, epoch: then) == nil)
    }

    @Test("A violation produces a complete user story")
    func violationSeedsAStory() throws {
        let v = Violation(
            summary: "No .editorconfig at the root", expected: "an .editorconfig at the root",
            actual: "absent", fixHint: nil)
        let seed = try #require(
            StandardsEngine.cardSeed(for: finding(.violating(v)), repo: repo, epoch: then))
        #expect(seed.story.isComplete)
        #expect(!seed.story.acceptanceCriteria.isEmpty)
        // The rubric, the expected/actual pair and the command are all on the
        // card, so the agent that picks it up does not have to re-derive them.
        #expect(seed.body.contains("gh api"))
        #expect(seed.body.contains("an .editorconfig at the root"))
    }

    /// The same sweep must not file twice; a LATER recurrence must be filable.
    /// A permanent key means an expired exemption can never produce a card
    /// again, because `createCard` returns the archived original.
    @Test("The key is stable within an epoch and changes across them")
    func keyCarriesTheEpoch() throws {
        let v = Violation(summary: "s", expected: "e", actual: "a", fixHint: nil)
        let a = try #require(StandardsEngine.cardSeed(
            for: finding(.violating(v)), repo: repo, epoch: then))
        let b = try #require(StandardsEngine.cardSeed(
            for: finding(.violating(v)), repo: repo, epoch: then))
        let later = try #require(StandardsEngine.cardSeed(
            for: finding(.violating(v)), repo: repo, epoch: then.addingTimeInterval(86_400)))
        #expect(a.idempotencyKey == b.idempotencyKey)
        #expect(a.idempotencyKey != later.idempotencyKey)
        #expect(a.idempotencyKey.hasPrefix("standard:phmatray/Foo:editorconfig:"))
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd ElliotKit && swift test --filter StandardCardSeedTests`
Expected: FAIL — `type 'StandardsEngine' has no member 'cardSeed'`.

- [ ] **Step 3: Write the implementation**

Add `StandardCardSeed` to `StandardVerdict.swift` and `cardSeed` to
`StandardsEngine.swift`:

```swift
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
    public static func cardSeed(
        for finding: StandardFinding, repo: GHRepoSummary, epoch: Date
    ) -> StandardCardSeed?
```

The story is built from the axis, not from prose: `role` is `"maintainer"`,
`want` restates the axis's expectation, `benefit` restates why the axis exists,
and the acceptance criteria are the expectation plus "the standards sweep reports
this repository compliant". The body carries `standard.rubric`, the
expected/actual pair, every `Provenance.command`, and the observation's age.

- [ ] **Step 4: Run it to verify it passes**

Run: `cd ElliotKit && swift test --filter StandardCardSeedTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add ElliotKit/Sources/ElliotModel/StandardVerdict.swift ElliotKit/Sources/ElliotModel/StandardsEngine.swift ElliotKit/Tests/ElliotModelTests/StandardCardSeedTests.swift
git commit -m "feat(model): describe the card a standards violation deserves"
```

---

## Done when

- `cd ElliotKit && swift test` is green, sampled five times.
- `StandardsEngine.assess` returns one finding per axis for any input, including
  an unreadable universe and an unreadable exemptions file.
- No `?? []`, no `try?`-with-default and no `Date()` anywhere under
  `Sources/ElliotModel/Standard*.swift`. Check with:
  ```bash
  grep -nE '\?\? \[\]|try\?|Date\(\)' ElliotKit/Sources/ElliotModel/Standard*.swift ElliotKit/Sources/ElliotModel/Reading.swift ElliotKit/Sources/ElliotModel/RepoMeasurement.swift
  ```
  Expected: no output.
- Nothing outside `RepoMeasurement.swift` reaches a tree's raw path set:
  ```bash
  grep -rn '\.storage' ElliotKit/Sources/ | grep -v RepoMeasurement.swift
  ```
  Expected: no output.

Plan 2 (collection and persistence) begins where this ends: `StandardsService`
filling a `RepoMeasurement` from `GHClient`, migration v9, and `fake-gh.sh`
learning the three subcommands this needs.
