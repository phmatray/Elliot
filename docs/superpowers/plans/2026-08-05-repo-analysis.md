# Repository Analysis Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Read a registered repository through six lenses with `claude -p`, harvest structured user stories from a JSON artifact each run writes, and let a person (or an agent over MCP) accept the ones worth keeping into the Backlog.

**Architecture:** One `claude -p` run per angle, carried by the existing `SkillRun` machinery (scheduling, streaming, durable log, cancellation, reconciliation). Each run writes `stories.json` at a path announced in its prompt; `ProposalHarvester` decodes it, resolves the cited evidence against the repository, hints at duplicates, and writes `storyProposal` rows. Proposals are not cards: accepting one calls `BoardService.createCard`, the single funnel that already exists. The rule engine, `TriggerAction`, the five columns and the three transitions are untouched.

**Tech Stack:** Swift 6.3.3, Swift 6 language mode, macOS 15 deployment target, SwiftPM (`ElliotKit`), GRDB 7, MCP Swift SDK 0.12, swift-testing.

**Spec:** `docs/superpowers/specs/2026-08-05-repo-analysis-design.md`. Read it before Task 1.

## Global Constraints

- Swift 6 language mode. Every new type crossing a concurrency boundary is `Sendable`.
- `ElliotModel` has **no dependencies**. Nothing in it may import GRDB, Foundation's process APIs, or touch the filesystem. Pure functions only.
- `ElliotMCPKit` must keep importing neither `ElliotEngine` nor `ElliotProcess`.
- Public API needs explicit `public init` — Swift's memberwise initialiser is internal.
- Decoders never throw and never drop silently: they return what they kept **and** why they dropped the rest.
- Nothing written back into the board is parsed out of an agent's prose. For analysis the analogue is: the artifact is the fact.
- Comments explain *why*, matching the density and tone of the surrounding code. No comment that restates the line below it.
- Run `cd ElliotKit && swift test` before every commit. All tests must pass — the suite is at 155 before this plan starts.
- Commit after every task with a message that says what changed and why.

---

### Task 1: The analysis model — angles, proposals, evidence

**Files:**
- Create: `ElliotKit/Sources/ElliotModel/AnalysisAngle.swift`
- Create: `ElliotKit/Sources/ElliotModel/StoryProposal.swift`
- Create: `ElliotKit/Sources/ElliotModel/Analysis.swift`
- Test: `ElliotKit/Tests/ElliotModelTests/AnalysisModelTests.swift`

**Interfaces:**
- Consumes: `UserStory` from `ElliotModel/UserStory.swift`, and its internal `String.trimmed()` helper.
- Produces: `AnalysisAngle` (enum, 6 cases, `.title` / `.symbol` / `.briefing`), `Effort.parse(_:)`, `Evidence` with `Evidence.parse(_:)`, `ProposedStory`, `StoryProposal`, `ProposalStatus`, `DuplicateHint`, `Analysis`, `AnalysisOrigin`, `AnalysisRunReport`.

- [x] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotModelTests/AnalysisModelTests.swift`:

```swift
import Foundation
import Testing

@testable import ElliotModel

@Suite("Analysis model")
struct AnalysisModelTests {

    @Test("Every angle carries a briefing that says what to leave alone", arguments: AnalysisAngle.allCases)
    func everyAngleIsBriefed(angle: AnalysisAngle) {
        #expect(!angle.title.isEmpty)
        #expect(!angle.symbol.isEmpty)
        // Without the second half every lens drifts back into generic review.
        #expect(angle.briefing.count > 120)
        #expect(angle.briefing.lowercased().contains("leave"))
    }

    @Test("Angle titles and symbols are distinct")
    func anglesAreDistinguishable() {
        #expect(Set(AnalysisAngle.allCases.map(\.title)).count == AnalysisAngle.allCases.count)
        #expect(Set(AnalysisAngle.allCases.map(\.symbol)).count == AnalysisAngle.allCases.count)
    }

    @Test("An unrecognised effort degrades rather than dropping the story", arguments: [
        ("small", Effort.small), ("MEDIUM", .medium), (" large ", .large),
        ("XL", .medium), ("", .medium), ("trivial", .medium),
    ])
    func effortParsing(raw: String, expected: Effort) {
        #expect(Effort.parse(raw) == expected)
    }

    @Test("Evidence splits on the trailing line number only", arguments: [
        ("Sources/A.swift:42", "Sources/A.swift", 42 as Int?),
        ("Sources/A.swift", "Sources/A.swift", nil),
        ("  Sources/A.swift:7  ", "Sources/A.swift", 7),
        // A colon that is not a line number belongs to the path.
        ("Sources/A.swift:notaline", "Sources/A.swift:notaline", nil),
        ("a:b:12", "a:b", 12),
    ])
    func evidenceParsing(raw: String, path: String, line: Int?) throws {
        let parsed = try #require(Evidence.parse(raw))
        #expect(parsed.path == path)
        #expect(parsed.line == line)
    }

    @Test("Evidence with no path at all is not evidence", arguments: ["", "   ", ":42"])
    func emptyEvidenceIsRejected(raw: String) {
        #expect(Evidence.parse(raw) == nil)
    }

    @Test("A proposal carries the story type the board already speaks")
    func proposalHoldsAUserStory() {
        let proposal = StoryProposal(
            analysisID: UUID(), runID: UUID(), repoID: UUID(), angle: .quickWins,
            title: "Add --json to the preflight CLI",
            story: UserStory(
                role: "developer", want: "preflight output as JSON",
                benefit: "I can gate CI on it", acceptanceCriteria: ["exit code reflects failures"]
            ),
            rationale: "The checks already exist; only the rendering is human-only.",
            evidence: [Evidence(path: "Sources/ElliotEngine/PreflightService.swift", line: 12, exists: true)],
            effort: .small,
            createdAt: Date()
        )
        #expect(proposal.status == .proposed)
        #expect(proposal.story.isComplete)
        #expect(proposal.story.narrative.hasPrefix("As a developer, I want"))
    }

    @Test("A duplicate hint says what it collided with")
    func duplicateHintLabels() {
        #expect(DuplicateHint.issue(number: 12, title: "Idle leak").label.contains("#12"))
        #expect(DuplicateHint.card(id: UUID(), title: "Dark mode").label.contains("Dark mode"))
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter AnalysisModelTests`
Expected: FAIL — `cannot find 'AnalysisAngle' in scope`.

- [x] **Step 3: Write `AnalysisAngle.swift`**

```swift
import Foundation

/// A lens the repository is read through.
///
/// The lens is data, not a code path: `briefing` is the paragraph handed to the
/// model, so adding an angle is a case and a paragraph. Each briefing says both
/// what to look for *and* what to leave alone — without the second half every
/// lens drifts back towards generic code review, and six lenses return the same
/// six lists.
public enum AnalysisAngle: String, Codable, CaseIterable, Sendable, Hashable {
    case bugs
    case quickWins
    case features
    case techDebt
    case tests
    case docsAndDX

    public var title: String {
        switch self {
        case .bugs: "Bugs"
        case .quickWins: "Quick wins"
        case .features: "Features"
        case .techDebt: "Tech debt"
        case .tests: "Tests"
        case .docsAndDX: "Docs & DX"
        }
    }

    public var symbol: String {
        switch self {
        case .bugs: "🐛"
        case .quickWins: "⚡"
        case .features: "✨"
        case .techDebt: "🧹"
        case .tests: "🧪"
        case .docsAndDX: "📖"
        }
    }

    public var briefing: String {
        switch self {
        case .bugs:
            """
            Look for defects: races and ordering assumptions, errors that are \
            swallowed or logged and then ignored, unhandled edge cases, \
            resources that leak on the failure path, off-by-one and boundary \
            handling, and state that can be observed half-updated. Prefer a \
            defect you can point at in the code over one you can imagine. \
            Leave style, naming and personal preference alone.
            """
        case .quickWins:
            """
            Look for changes with a high ratio of value to effort: something a \
            developer could finish in one sitting, that carries little risk, \
            and that removes a recurring irritation or unblocks something else. \
            Prefer what is already half-built over what must be designed. \
            Leave anything architectural alone — if it needs a new abstraction, \
            it is not a quick win.
            """
        case .features:
            """
            Look for capabilities the shape of this repository is asking for: \
            what the existing types almost support, what a user of this code \
            would reach for next, what a half-finished seam suggests was \
            intended. Ground each one in what is already there. Leave alone \
            anything that duplicates a capability the repository already has \
            elsewhere, and anything that would be a different product.
            """
        case .techDebt:
            """
            Look for structure that is costing something now: duplicated logic \
            that has already drifted, boundaries that leak so callers must know \
            internals, files that have grown to do several unrelated jobs, and \
            abstractions that no longer match how they are used. Say what the \
            cost is. Leave cosmetic renames and reformatting alone.
            """
        case .tests:
            """
            Look for invariants the code depends on but no test asserts: error \
            paths, cancellation, concurrency, boundary values, and the exact \
            behaviours a comment claims. Prefer one test that would have caught \
            a real bug over ten that restate the implementation. Leave alone \
            anything whose only justification is raising a coverage number.
            """
        case .docsAndDX:
            """
            Look for friction a newcomer hits: setup steps that are implied \
            rather than written, error messages that do not say what to do \
            next, commands that need flags nobody would guess, and documented \
            behaviour that no longer matches the code. Leave typos and prose \
            polish alone.
            """
        }
    }
}
```

- [x] **Step 4: Write `StoryProposal.swift`**

```swift
import Foundation

/// What the agent writes into the artifact.
///
/// Deliberately not `StoryProposal`: this is a contract we ask a model to
/// satisfy, so it stays flat, small and forgiving. Missing optional fields
/// decode to empty rather than failing the whole file — a story is dropped for
/// being unusable, never for being untidy.
public struct ProposedStory: Codable, Sendable, Hashable {
    public var title: String
    public var role: String
    public var want: String
    public var benefit: String
    public var acceptanceCriteria: [String]
    public var rationale: String
    /// `"Sources/ElliotProcess/ClaudeRunner.swift:142"`. At least one required.
    public var evidence: [String]
    /// `small` | `medium` | `large`; anything else degrades to medium.
    public var effort: String

    public init(
        title: String,
        role: String,
        want: String,
        benefit: String,
        acceptanceCriteria: [String] = [],
        rationale: String = "",
        evidence: [String] = [],
        effort: String = "medium"
    ) {
        self.title = title
        self.role = role
        self.want = want
        self.benefit = benefit
        self.acceptanceCriteria = acceptanceCriteria
        self.rationale = rationale
        self.evidence = evidence
        self.effort = effort
    }

    // Both spellings of the multi-word keys are accepted. Which one a model
    // emits varies between runs, and losing a whole story to a naming
    // convention would be an absurd way to fail.
    private enum CodingKeys: String, CodingKey {
        case title, role, want, benefit, rationale, evidence, effort
        case acceptanceCriteriaSnake = "acceptance_criteria"
        case acceptanceCriteria
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? ""
        want = try container.decodeIfPresent(String.self, forKey: .want) ?? ""
        benefit = try container.decodeIfPresent(String.self, forKey: .benefit) ?? ""
        acceptanceCriteria =
            try container.decodeIfPresent([String].self, forKey: .acceptanceCriteria)
            ?? container.decodeIfPresent([String].self, forKey: .acceptanceCriteriaSnake)
            ?? []
        rationale = try container.decodeIfPresent(String.self, forKey: .rationale) ?? ""
        evidence = try container.decodeIfPresent([String].self, forKey: .evidence) ?? []
        effort = try container.decodeIfPresent(String.self, forKey: .effort) ?? "medium"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(role, forKey: .role)
        try container.encode(want, forKey: .want)
        try container.encode(benefit, forKey: .benefit)
        try container.encode(acceptanceCriteria, forKey: .acceptanceCriteria)
        try container.encode(rationale, forKey: .rationale)
        try container.encode(evidence, forKey: .evidence)
        try container.encode(effort, forKey: .effort)
    }

    /// The three parts the board requires. Checked before a proposal is kept,
    /// so an incomplete story is refused here rather than at the first drag.
    public var isUsable: Bool {
        ![title, role, want, benefit].contains { $0.trimmed().isEmpty } && !evidence.isEmpty
    }

    public var story: UserStory {
        UserStory(
            role: role, want: want, benefit: benefit,
            acceptanceCriteria: acceptanceCriteria
                .map { $0.trimmed() }
                .filter { !$0.isEmpty }
        )
    }
}

public enum Effort: String, Codable, CaseIterable, Sendable, Hashable {
    case small, medium, large

    /// Anything unrecognised becomes `.medium`. A wrong size is a nuisance; a
    /// dropped story is a loss.
    public static func parse(_ raw: String) -> Effort {
        Effort(rawValue: raw.trimmed().lowercased()) ?? .medium
    }
}

/// A place in the repository a proposal points at.
///
/// The only objective fact available about an opinion: either the file is there
/// or it is not. `exists` is resolved once, at harvest.
public struct Evidence: Codable, Sendable, Hashable {
    public var path: String
    public var line: Int?
    public var exists: Bool

    public init(path: String, line: Int? = nil, exists: Bool = false) {
        self.path = path
        self.line = line
        self.exists = exists
    }

    /// Splits `"Sources/Foo.swift:42"` into its parts.
    ///
    /// The split is on the *last* colon and only when everything after it is
    /// digits, so a path that legitimately contains a colon keeps it.
    public static func parse(_ raw: String) -> (path: String, line: Int?)? {
        let trimmed = raw.trimmed()
        guard !trimmed.isEmpty else { return nil }
        guard let colon = trimmed.lastIndex(of: ":") else { return (trimmed, nil) }
        let tail = trimmed[trimmed.index(after: colon)...]
        guard !tail.isEmpty, tail.allSatisfy(\.isNumber), let line = Int(tail) else {
            return (trimmed, nil)
        }
        let path = String(trimmed[..<colon])
        guard !path.isEmpty else { return nil }
        return (path, line)
    }

    public var display: String {
        line.map { "\(path):\($0)" } ?? path
    }
}

public enum ProposalStatus: String, Codable, CaseIterable, Sendable, Hashable {
    case proposed, accepted, rejected
}

/// What a proposal appears to collide with. A hint, never a refusal: the
/// decision to skip a near-duplicate is the reader's.
public enum DuplicateHint: Codable, Sendable, Hashable {
    case card(id: UUID, title: String)
    case issue(number: Int, title: String)

    public var label: String {
        switch self {
        case .card(_, let title): "looks like the card “\(title)”"
        case .issue(let number, let title): "looks like issue #\(number) — \(title)"
        }
    }
}

/// A story the analysis suggests, kept out of the board until someone accepts it.
public struct StoryProposal: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var analysisID: UUID
    public var runID: UUID
    public var repoID: UUID
    public var angle: AnalysisAngle
    public var title: String
    /// The type the board already speaks. Reusing it is the point of the feature.
    public var story: UserStory
    public var rationale: String
    public var evidence: [Evidence]
    public var effort: Effort
    public var status: ProposalStatus
    public var acceptedCardID: UUID?
    public var duplicateOf: DuplicateHint?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        analysisID: UUID,
        runID: UUID,
        repoID: UUID,
        angle: AnalysisAngle,
        title: String,
        story: UserStory,
        rationale: String = "",
        evidence: [Evidence] = [],
        effort: Effort = .medium,
        status: ProposalStatus = .proposed,
        acceptedCardID: UUID? = nil,
        duplicateOf: DuplicateHint? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.analysisID = analysisID
        self.runID = runID
        self.repoID = repoID
        self.angle = angle
        self.title = title
        self.story = story
        self.rationale = rationale
        self.evidence = evidence
        self.effort = effort
        self.status = status
        self.acceptedCardID = acceptedCardID
        self.duplicateOf = duplicateOf
        self.createdAt = createdAt
    }

    /// True when every cited file was found. The fastest signal that a story
    /// was found rather than invented.
    public var isGrounded: Bool {
        !evidence.isEmpty && evidence.allSatisfy(\.exists)
    }
}
```

- [x] **Step 5: Write `Analysis.swift`**

```swift
import Foundation

/// One reading of a repository, through one or more lenses.
///
/// There is deliberately **no `state` field**. An analysis is running while any
/// of its runs is non-terminal, and its runs already answer that. A stored
/// counter would be a second reservoir of truth that drifts on the first crash
/// — the same reason a card has no "is running" flag.
public struct Analysis: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var repoID: UUID
    public var angles: [AnalysisAngle]
    /// Free text folded into every angle's prompt. This is the custom lens: a
    /// seventh enum case would need a briefing, this needs a sentence.
    public var extraInstructions: String
    public var maxStoriesPerAngle: Int
    public var origin: AnalysisOrigin
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        repoID: UUID,
        angles: [AnalysisAngle],
        extraInstructions: String = "",
        maxStoriesPerAngle: Int = 8,
        origin: AnalysisOrigin = .manual,
        createdAt: Date
    ) {
        self.id = id
        self.repoID = repoID
        self.angles = angles
        self.extraInstructions = extraInstructions
        self.maxStoriesPerAngle = maxStoriesPerAngle
        self.origin = origin
        self.createdAt = createdAt
    }
}

public enum AnalysisOrigin: Codable, Sendable, Hashable {
    case manual
    case mcp(client: String)
}

/// What an analysis run has to say about itself, written onto the run when it
/// finishes.
///
/// One nullable column rather than four: every field here is meaningless for a
/// card run, and keeping them together makes that obvious.
public struct AnalysisRunReport: Codable, Sendable, Hashable {
    public enum HarvestSource: String, Codable, Sendable, Hashable {
        /// The artifact the prompt asked for.
        case artifact
        /// A fenced JSON block recovered from the closing message.
        case resultText
        case none
    }

    public var harvestSource: HarvestSource
    public var kept: Int
    /// Why each dropped story was dropped. Shown, never swallowed.
    public var dropped: [String]
    /// The git sentinel. An analysis has no business writing to the repository
    /// and Elliot cannot prevent it, so it checks the outcome instead.
    public var workingTreeChanged: Bool
    /// `git status --porcelain` after the run, when it differs from before.
    public var workingTreeDiff: String?

    public init(
        harvestSource: HarvestSource,
        kept: Int = 0,
        dropped: [String] = [],
        workingTreeChanged: Bool = false,
        workingTreeDiff: String? = nil
    ) {
        self.harvestSource = harvestSource
        self.kept = kept
        self.dropped = dropped
        self.workingTreeChanged = workingTreeChanged
        self.workingTreeDiff = workingTreeDiff
    }
}
```

- [x] **Step 6: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter AnalysisModelTests`
Expected: PASS, all cases.

- [x] **Step 7: Run the whole suite**

Run: `cd ElliotKit && swift test`
Expected: PASS — 155 existing tests plus the new ones. Nothing else was touched.

- [x] **Step 8: Commit**

```bash
git add ElliotKit/Sources/ElliotModel/AnalysisAngle.swift \
        ElliotKit/Sources/ElliotModel/StoryProposal.swift \
        ElliotKit/Sources/ElliotModel/Analysis.swift \
        ElliotKit/Tests/ElliotModelTests/AnalysisModelTests.swift
git commit -m "feat(model): the analysis lenses, and a proposal that is not a card

The six angles carry their own briefing, so a lens is data rather than a
code path. Each briefing says what to leave alone as well as what to look
for — without that half, six lenses return the same six lists.

A proposal holds the UserStory the board already speaks, plus the one
objective fact available about an opinion: whether the files it cites are
actually there."
```

---

### Task 2: Move the token-overlap heuristic into the model

**Files:**
- Create: `ElliotKit/Sources/ElliotModel/TextSimilarity.swift`
- Modify: `ElliotKit/Sources/ElliotEngine/Verifier.swift:127-140`
- Test: `ElliotKit/Tests/ElliotModelTests/TextSimilarityTests.swift`

**Interfaces:**
- Produces: `TextSimilarity.tokens(_:) -> Set<String>`, `TextSimilarity.overlap(_:_:) -> Double`, `TextSimilarity.duplicateThreshold: Double` (0.6), `TextSimilarity.bestMatch(for:among:threshold:) -> (index: Int, score: Double)?`.
- `Verifier.tokens` and `Verifier.overlap` stay as thin forwarders so existing call sites and tests do not move.

- [x] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotModelTests/TextSimilarityTests.swift`:

```swift
import Testing

@testable import ElliotModel

@Suite("Text similarity")
struct TextSimilarityTests {

    @Test("Short words are noise and are dropped")
    func shortWordsAreDropped() {
        #expect(TextSimilarity.tokens("a to be or not to be") == ["not"])
    }

    @Test("Tokens ignore case and punctuation")
    func tokensNormalise() {
        #expect(TextSimilarity.tokens("Dark-Mode toggle!") == ["dark", "mode", "toggle"])
    }

    @Test("Overlap measures how much of the wanted vocabulary is covered")
    func overlapIsAsymmetric() {
        let wanted = TextSimilarity.tokens("dark mode toggle")
        #expect(TextSimilarity.overlap(wanted, TextSimilarity.tokens("Add a dark mode toggle")) == 1.0)
        #expect(TextSimilarity.overlap(wanted, TextSimilarity.tokens("dark mode")) > 0.6)
        #expect(TextSimilarity.overlap(wanted, TextSimilarity.tokens("rename the runner")) == 0.0)
        #expect(TextSimilarity.overlap([], TextSimilarity.tokens("anything")) == 0.0)
    }

    @Test("The best match is the highest scorer above the threshold")
    func bestMatchPicksTheHighest() throws {
        let candidates = ["Rename the runner", "Add a dark mode toggle", "Dark mode"]
        let match = try #require(TextSimilarity.bestMatch(for: "dark mode toggle", among: candidates))
        #expect(match.index == 1)
        #expect(match.score == 1.0)
    }

    @Test("Nothing above the threshold is no match, not a weak one")
    func belowThresholdIsNil() {
        #expect(TextSimilarity.bestMatch(for: "dark mode toggle", among: ["rename the runner"]) == nil)
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter TextSimilarityTests`
Expected: FAIL — `cannot find 'TextSimilarity' in scope`.

- [x] **Step 3: Write `TextSimilarity.swift`**

```swift
import Foundation

/// How close two short human titles are.
///
/// Used in two places that must agree: recovering an issue by title when a run
/// log yielded no URL, and hinting that a proposed story is already on the
/// board. Two implementations of one heuristic would diverge, and the second
/// one would diverge silently.
public enum TextSimilarity {
    /// The score at and above which two titles are treated as the same thing.
    public static let duplicateThreshold = 0.6

    /// Words worth comparing. Anything three characters or shorter is dropped:
    /// "the", "a", "to" match everything and mean nothing.
    public static func tokens(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count > 2 }
        )
    }

    /// How much of the wanted vocabulary a candidate covers.
    ///
    /// Deliberately asymmetric: a long candidate that contains every wanted word
    /// scores 1.0. "Add a dark mode toggle to the board" *is* "dark mode toggle".
    public static func overlap(_ wanted: Set<String>, _ candidate: Set<String>) -> Double {
        guard !wanted.isEmpty else { return 0 }
        return Double(wanted.intersection(candidate).count) / Double(wanted.count)
    }

    /// The best candidate above the threshold, or nothing.
    public static func bestMatch(
        for text: String,
        among candidates: [String],
        threshold: Double = duplicateThreshold
    ) -> (index: Int, score: Double)? {
        let wanted = tokens(text)
        guard !wanted.isEmpty else { return nil }
        return candidates
            .enumerated()
            .map { (index: $0.offset, score: overlap(wanted, tokens($0.element))) }
            .filter { $0.score >= threshold }
            .max { $0.score < $1.score }
    }
}
```

- [x] **Step 4: Point `Verifier` at it**

In `ElliotKit/Sources/ElliotEngine/Verifier.swift`, replace the two static helpers at the end of the file (lines 127-140) with forwarders:

```swift
    // The heuristic itself lives in ElliotModel: the proposal harvester needs
    // exactly this scoring to hint at duplicates, and one implementation is the
    // only way the two stay agreed.
    static func tokens(_ text: String) -> Set<String> { TextSimilarity.tokens(text) }

    static func overlap(_ wanted: Set<String>, _ candidate: Set<String>) -> Double {
        TextSimilarity.overlap(wanted, candidate)
    }
```

Replace the literal `0.6` on line 53 with `TextSimilarity.duplicateThreshold`:

```swift
                .filter { $0.1 >= TextSimilarity.duplicateThreshold }
```

- [x] **Step 5: Run the whole suite**

Run: `cd ElliotKit && swift test`
Expected: PASS. The verifier's behaviour is unchanged — this is a move, not a change.

- [x] **Step 6: Commit**

```bash
git add ElliotKit/Sources/ElliotModel/TextSimilarity.swift \
        ElliotKit/Sources/ElliotEngine/Verifier.swift \
        ElliotKit/Tests/ElliotModelTests/TextSimilarityTests.swift
git commit -m "refactor(model): one implementation of the title-overlap heuristic

The harvester needs exactly the scoring the issue-recovery sweep already
uses. Two copies of one heuristic diverge, and the second one diverges
without anyone noticing."
```

---

### Task 3: The analysis prompt

**Files:**
- Create: `ElliotKit/Sources/ElliotModel/AnalysisPromptBuilder.swift`
- Test: `ElliotKit/Tests/ElliotModelTests/AnalysisPromptBuilderTests.swift`

**Interfaces:**
- Consumes: `AnalysisAngle` from Task 1.
- Produces: `AnalysisPromptBuilder.outputMarker` (`"ELLIOT_OUTPUT="`), `.maxExistingTitles` (80), `.prompt(angle:repoNameWithOwner:outputPath:existingTitles:maxStories:extraInstructions:githubTitlesAvailable:) -> String`, `.outputPath(in:) -> String?`.

**Why the marker matters:** `fake-claude.sh` (Task 11) finds the artifact path by grepping the prompt for exactly this marker, and so does the runtime contract. If the prompt ever announced two paths, or a relative one, the artifact would be written somewhere Elliot never looks — the same class of failure as an `implement-issue` prompt carrying a stray number. Hence the property test.

- [x] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotModelTests/AnalysisPromptBuilderTests.swift`:

```swift
import Testing

@testable import ElliotModel

@Suite("Analysis prompt")
struct AnalysisPromptBuilderTests {

    private func build(
        angle: AnalysisAngle = .bugs,
        titles: [String] = [],
        maxStories: Int = 8,
        extra: String = "",
        githubAvailable: Bool = true
    ) -> String {
        AnalysisPromptBuilder.prompt(
            angle: angle,
            repoNameWithOwner: "phmatray/Elliot",
            outputPath: "/tmp/elliot/analyses/A/B/stories.json",
            existingTitles: titles,
            maxStories: maxStories,
            extraInstructions: extra,
            githubTitlesAvailable: githubAvailable
        )
    }

    /// The invariant the whole harvest depends on, in the same spirit as
    /// "the first digit run of an implement-issue prompt is the issue number".
    @Test("The prompt announces exactly one output path, and it is absolute",
          arguments: AnalysisAngle.allCases)
    func exactlyOneAbsoluteOutputPath(angle: AnalysisAngle) throws {
        let prompt = build(angle: angle, titles: ["Dark mode", "Run log"], extra: "focus on ElliotProcess")
        let occurrences = prompt.components(separatedBy: AnalysisPromptBuilder.outputMarker).count - 1
        #expect(occurrences == 1)

        let path = try #require(AnalysisPromptBuilder.outputPath(in: prompt))
        #expect(path == "/tmp/elliot/analyses/A/B/stories.json")
        #expect(path.hasPrefix("/"))
    }

    @Test("The angle's briefing is what makes one prompt differ from another")
    func theBriefingIsCarried() {
        for angle in AnalysisAngle.allCases {
            #expect(build(angle: angle).contains(angle.briefing))
        }
        #expect(build(angle: .bugs) != build(angle: .tests))
    }

    @Test("The prompt names the repository and the cap")
    func promptCarriesItsSubject() {
        let prompt = build(maxStories: 5)
        #expect(prompt.contains("phmatray/Elliot"))
        #expect(prompt.contains("5"))
        #expect(prompt.lowercased().contains("do not modify"))
        #expect(prompt.contains("\"acceptance_criteria\""))
    }

    @Test("Existing titles are listed, newest first, and capped")
    func existingTitlesAreCapped() {
        let titles = (1...200).map { "Existing story \($0)" }
        let prompt = build(titles: titles)
        #expect(prompt.contains("Existing story 1"))
        #expect(!prompt.contains("Existing story 100"))
        let listed = prompt
            .split(separator: "\n")
            .filter { $0.hasPrefix("- Existing story ") }
        #expect(listed.count == AnalysisPromptBuilder.maxExistingTitles)
    }

    @Test("With no titles at all the section is left out rather than left empty")
    func noTitlesNoSection() {
        #expect(!build(titles: []).contains("do not propose these again"))
    }

    @Test("When gh could not be reached the prompt says so instead of implying completeness")
    func partialDeduplicationIsAdmitted() {
        let prompt = build(titles: ["Dark mode"], githubAvailable: false)
        #expect(prompt.contains("could not be reached"))
    }

    @Test("Extra instructions are passed through verbatim")
    func extraInstructionsSurvive() {
        let extra = "Ignore the SwiftUI layer.\nLook hard at ElliotIPC."
        #expect(build(extra: extra).contains(extra))
    }

    @Test("An empty extra-instructions field adds nothing")
    func emptyExtraAddsNothing() {
        #expect(!build(extra: "   ").contains("Additional instructions"))
    }

    @Test("A prompt with no marker has no output path")
    func noMarkerNoPath() {
        #expect(AnalysisPromptBuilder.outputPath(in: "nothing here") == nil)
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter AnalysisPromptBuilderTests`
Expected: FAIL — `cannot find 'AnalysisPromptBuilder' in scope`.

- [x] **Step 3: Write `AnalysisPromptBuilder.swift`**

```swift
import Foundation

/// The prompt Elliot sends to read a repository through one lens.
///
/// Unlike the three lifecycle skills, this is **not** a slash command: there is
/// no `analyze-repo` skill in the plugin. Elliot owns this prompt and versions
/// it, which is why it is here — pure, and covered by tests that assert the one
/// thing the harvest cannot survive being wrong about.
public enum AnalysisPromptBuilder {
    /// How the artifact path is announced. Both the property test and
    /// `Scripts/fake-claude.sh` find the path by this exact marker.
    public static let outputMarker = "ELLIOT_OUTPUT="

    /// Enough context to recognise a duplicate, not so much that the list
    /// crowds out the briefing.
    public static let maxExistingTitles = 80

    public static func prompt(
        angle: AnalysisAngle,
        repoNameWithOwner: String,
        outputPath: String,
        existingTitles: [String],
        maxStories: Int,
        extraInstructions: String = "",
        githubTitlesAvailable: Bool = true
    ) -> String {
        var sections: [String] = []

        sections.append("""
            You are reading the repository \(repoNameWithOwner) for Elliot, a \
            Kanban board that turns proposals into GitHub issues.

            Read the code. Do not modify it: make no edits, no commits, no \
            branches, no formatting runs. The single file below is the only one \
            you may write.
            """)

        sections.append("What to look for:\n\n\(angle.briefing)")

        sections.append("""
            Write your findings as JSON to this exact path, and print nothing \
            else in your reply:

            \(outputMarker)\(outputPath)

            The file must contain a JSON array of at most \(maxStories) objects:

            [
              {
                "title": "Add --json to the preflight CLI",
                "role": "developer",
                "want": "preflight results as machine-readable JSON",
                "benefit": "I can fail a CI job on a broken setup",
                "acceptance_criteria": [
                  "`elliot preflight --json` prints one object per check",
                  "the exit code is non-zero when any check fails"
                ],
                "rationale": "The checks already exist and are only rendered \
            for humans, so this is rendering rather than new logic.",
                "evidence": ["Sources/ElliotEngine/PreflightService.swift:31"],
                "effort": "small"
              }
            ]

            Rules:
            - `role`, `want` and `benefit` are the three parts of a user story. \
            All three are required; a story missing one is discarded.
            - `evidence` must cite at least one real file, as a path relative to \
            the repository root, optionally with a line number after a colon. A \
            story that cites nothing is discarded — it cannot be judged.
            - `effort` is one of small, medium, large.
            - Return fewer than \(maxStories) rather than padding the list.
            """)

        let titles = Array(existingTitles.prefix(maxExistingTitles))
        if !titles.isEmpty {
            var section = """
                Already on the board or already filed — do not propose these again:

                \(titles.map { "- \($0)" }.joined(separator: "\n"))
                """
            if !githubTitlesAvailable {
                // Saying the check was partial is better than letting the model
                // assume this list is the whole picture.
                section += "\n\nGitHub could not be reached, so this list covers "
                    + "the board only and may be missing open issues."
            }
            sections.append(section)
        } else if !githubTitlesAvailable {
            sections.append(
                "GitHub could not be reached and the board is empty, so no "
                + "duplicate check was possible."
            )
        }

        let extra = extraInstructions.trimmed()
        if !extra.isEmpty {
            sections.append("Additional instructions from the person asking:\n\n\(extra)")
        }

        return sections.joined(separator: "\n\n")
    }

    /// The artifact path a prompt announces. The runtime counterpart of the
    /// property test, and the same thing the fake `claude` does in shell.
    public static func outputPath(in prompt: String) -> String? {
        guard let range = prompt.range(of: outputMarker) else { return nil }
        let tail = prompt[range.upperBound...].prefix { !$0.isWhitespace }
        return tail.isEmpty ? nil : String(tail)
    }
}
```

- [x] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter AnalysisPromptBuilderTests`
Expected: PASS.

If `existingTitlesAreCapped` fails on the `- Existing story ` prefix count, check that the joined list uses `"- "` and that no other section emits lines starting with `- Existing story `.

- [x] **Step 5: Run the whole suite and commit**

```bash
cd ElliotKit && swift test && cd ..
git add ElliotKit/Sources/ElliotModel/AnalysisPromptBuilder.swift \
        ElliotKit/Tests/ElliotModelTests/AnalysisPromptBuilderTests.swift
git commit -m "feat(model): the analysis prompt, and the one thing it must get right

There is no analyze-repo skill, so unlike the other three this prompt is
Elliot's own. The harvest cannot survive the artifact being written
somewhere Elliot does not look, so the property test asserts the prompt
announces exactly one output path and that it is absolute — the same kind
of invariant as the first digit run of an implement-issue prompt."
```

---

### Task 4: The proposal decoder

**Files:**
- Create: `ElliotKit/Sources/ElliotModel/ProposalDecoder.swift`
- Create: `Fixtures/analysis/valid.json`
- Create: `Fixtures/analysis/messy.json`
- Test: `ElliotKit/Tests/ElliotModelTests/ProposalDecoderTests.swift`

**Interfaces:**
- Consumes: `ProposedStory`, `Effort` from Task 1.
- Produces: `ProposalDecoder.Harvest` (`stories: [ProposedStory]`, `dropped: [String]`), `ProposalDecoder.decode(artifact:maxStories:)`, `ProposalDecoder.decode(resultText:maxStories:)`, `ProposalDecoder.lastFencedJSONBlock(in:)`.

**Contract:** the same one the stream-json decoder holds — **never throws, never drops silently**. Every discarded story leaves a sentence saying why, and the window shows those sentences.

- [x] **Step 1: Write the fixtures**

Create `Fixtures/analysis/valid.json`:

```json
[
  {
    "title": "Add --json to the preflight CLI",
    "role": "developer",
    "want": "preflight results as machine-readable JSON",
    "benefit": "I can fail a CI job on a broken setup",
    "acceptance_criteria": ["one object per check", "non-zero exit on failure"],
    "rationale": "The checks exist and are only rendered for humans.",
    "evidence": ["Sources/ElliotEngine/PreflightService.swift:31"],
    "effort": "small"
  },
  {
    "title": "Cache the login-shell environment",
    "role": "user",
    "want": "Elliot to start without waiting on zsh",
    "benefit": "the board is usable immediately after launch",
    "acceptanceCriteria": ["the capture is reused until ~/.zshrc changes"],
    "rationale": "Every launch pays for a login shell.",
    "evidence": ["Sources/ElliotProcess/LoginShellEnvironment.swift"],
    "effort": "medium"
  }
]
```

Create `Fixtures/analysis/messy.json` — a wrapped array, an unknown field, a story with no benefit, a story with no evidence, and an unrecognised effort:

```json
{
  "stories": [
    {
      "title": "Keep this one",
      "role": "developer",
      "want": "to keep well-formed stories",
      "benefit": "the harvest is not all-or-nothing",
      "evidence": ["Sources/ElliotModel/ProposalDecoder.swift:1"],
      "effort": "enormous",
      "confidence": 0.8
    },
    {
      "title": "No benefit",
      "role": "developer",
      "want": "something",
      "evidence": ["Sources/A.swift:1"]
    },
    {
      "title": "No evidence",
      "role": "developer",
      "want": "something",
      "benefit": "something else",
      "evidence": []
    }
  ]
}
```

- [x] **Step 2: Write the failing test**

Create `ElliotKit/Tests/ElliotModelTests/ProposalDecoderTests.swift`:

```swift
import Foundation
import Testing

@testable import ElliotModel

/// Fixtures live at the repository root, not in a resource bundle: the same
/// files are opened by hand when reproducing a harvest.
private enum FixturePaths {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ElliotModelTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // ElliotKit
        .deletingLastPathComponent()   // repo root

    static func analysis(_ name: String) -> Data {
        (try? Data(contentsOf: root.appendingPathComponent("Fixtures/analysis/\(name)")))
            ?? Data()
    }
}

@Suite("Proposal decoder")
struct ProposalDecoderTests {

    @Test("A well-formed artifact decodes whole")
    func validArtifact() {
        let harvest = ProposalDecoder.decode(artifact: FixturePaths.analysis("valid.json"), maxStories: 8)
        #expect(harvest.stories.count == 2)
        #expect(harvest.dropped.isEmpty)
        #expect(harvest.stories[0].title == "Add --json to the preflight CLI")
        // Either spelling of the criteria key is accepted.
        #expect(harvest.stories[0].acceptanceCriteria.count == 2)
        #expect(harvest.stories[1].acceptanceCriteria == ["the capture is reused until ~/.zshrc changes"])
    }

    @Test("A wrapped array, unknown fields and unusable stories are all survivable")
    func messyArtifact() {
        let harvest = ProposalDecoder.decode(artifact: FixturePaths.analysis("messy.json"), maxStories: 8)
        #expect(harvest.stories.count == 1)
        #expect(harvest.stories[0].title == "Keep this one")
        #expect(Effort.parse(harvest.stories[0].effort) == .medium)
        #expect(harvest.dropped.count == 2)
        #expect(harvest.dropped.contains { $0.contains("No benefit") })
        #expect(harvest.dropped.contains { $0.contains("No evidence") })
    }

    @Test("Garbage is reported, not thrown", arguments: [
        "", "   ", "not json at all", "{}", "[1, 2, 3]", "{\"stories\": \"nope\"}",
    ])
    func garbageIsReported(raw: String) {
        let harvest = ProposalDecoder.decode(artifact: Data(raw.utf8), maxStories: 8)
        #expect(harvest.stories.isEmpty)
        #expect(!harvest.dropped.isEmpty)
    }

    @Test("Over the cap is trimmed, and the trim is announced")
    func capIsAnnounced() {
        let many = (1...30).map {
            """
            {"title":"S\($0)","role":"dev","want":"w","benefit":"b","evidence":["A.swift:1"]}
            """
        }.joined(separator: ",")
        let harvest = ProposalDecoder.decode(artifact: Data("[\(many)]".utf8), maxStories: 8)
        #expect(harvest.stories.count == 8)
        #expect(harvest.dropped.contains { $0.contains("22") })
    }

    @Test("The fenced-block fallback recovers an array from prose")
    func fencedFallback() {
        let text = """
            I looked at the runner and found two things worth filing.

            ```json
            [{"title":"T","role":"dev","want":"w","benefit":"b","evidence":["A.swift:1"]}]
            ```

            Let me know if you want more detail.
            """
        let harvest = ProposalDecoder.decode(resultText: text, maxStories: 8)
        #expect(harvest.stories.count == 1)
        #expect(harvest.stories[0].title == "T")
    }

    @Test("The last fenced block wins, so a schema echoed earlier does not")
    func lastFenceWins() {
        let text = """
            Here is the shape I will use:

            ```json
            [{"title":"EXAMPLE","role":"","want":"","benefit":"","evidence":[]}]
            ```

            And here is the result:

            ```json
            [{"title":"REAL","role":"dev","want":"w","benefit":"b","evidence":["A.swift:1"]}]
            ```
            """
        let harvest = ProposalDecoder.decode(resultText: text, maxStories: 8)
        #expect(harvest.stories.map(\.title) == ["REAL"])
    }

    @Test("Prose with no fenced block yields nothing and says so")
    func noFenceNoStories() {
        let harvest = ProposalDecoder.decode(resultText: "I could not find anything.", maxStories: 8)
        #expect(harvest.stories.isEmpty)
        #expect(harvest.dropped.contains { $0.lowercased().contains("no json") })
    }
}
```

- [x] **Step 3: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter ProposalDecoderTests`
Expected: FAIL — `cannot find 'ProposalDecoder' in scope`.

- [x] **Step 4: Write `ProposalDecoder.swift`**

```swift
import Foundation

/// Turns whatever an analysis run produced into stories.
///
/// The contract is the stream-json decoder's: **never throws, never drops
/// silently.** A model that emits one malformed story out of twelve should cost
/// one story, not the run; and every discarded story leaves a sentence saying
/// why, because "we found 8" and "we found 12 and threw 4 away" are different
/// results and the reader is entitled to know which one they are looking at.
public enum ProposalDecoder {
    public struct Harvest: Sendable, Hashable {
        public var stories: [ProposedStory]
        public var dropped: [String]

        public init(stories: [ProposedStory] = [], dropped: [String] = []) {
            self.stories = stories
            self.dropped = dropped
        }
    }

    /// The artifact the prompt asked for.
    public static func decode(artifact data: Data, maxStories: Int) -> Harvest {
        guard !data.isEmpty else {
            return Harvest(dropped: ["The artifact was empty."])
        }
        guard let raw = try? JSONSerialization.jsonObject(with: data) else {
            return Harvest(dropped: ["The artifact was not valid JSON."])
        }
        return decode(jsonObject: raw, maxStories: maxStories)
    }

    /// The fallback: a fenced JSON block in the closing message.
    public static func decode(resultText: String, maxStories: Int) -> Harvest {
        guard let block = lastFencedJSONBlock(in: resultText) else {
            return Harvest(dropped: ["No JSON block was found in the closing message."])
        }
        return decode(artifact: Data(block.utf8), maxStories: maxStories)
    }

    private static func decode(jsonObject raw: Any, maxStories: Int) -> Harvest {
        // A bare array is what was asked for; a wrapped one is what models
        // reach for anyway. Both are the same intent.
        let elements: [Any]
        switch raw {
        case let array as [Any]:
            elements = array
        case let object as [String: Any]:
            guard let array = (object["stories"] ?? object["proposals"]) as? [Any] else {
                return Harvest(dropped: ["The JSON was an object with no \"stories\" array."])
            }
            elements = array
        default:
            return Harvest(dropped: ["The JSON was neither an array nor an object."])
        }

        guard !elements.isEmpty else {
            return Harvest(dropped: ["The JSON contained no stories."])
        }

        var kept: [ProposedStory] = []
        var dropped: [String] = []

        for (index, element) in elements.enumerated() {
            guard
                let data = try? JSONSerialization.data(withJSONObject: element),
                let story = try? JSONDecoder().decode(ProposedStory.self, from: data)
            else {
                dropped.append("Story \(index + 1) was not an object with the expected shape.")
                continue
            }
            guard story.isUsable else {
                dropped.append(reasonUnusable(story, index: index))
                continue
            }
            kept.append(story)
        }

        if kept.count > maxStories {
            dropped.append(
                "\(kept.count - maxStories) stories over the cap of \(maxStories) were dropped."
            )
            kept = Array(kept.prefix(maxStories))
        }

        return Harvest(stories: kept, dropped: dropped)
    }

    private static func reasonUnusable(_ story: ProposedStory, index: Int) -> String {
        let name = story.title.trimmed().isEmpty ? "Story \(index + 1)" : "“\(story.title)”"
        var missing: [String] = []
        if story.title.trimmed().isEmpty { missing.append("title") }
        if story.role.trimmed().isEmpty { missing.append("role") }
        if story.want.trimmed().isEmpty { missing.append("want") }
        if story.benefit.trimmed().isEmpty { missing.append("benefit") }
        if story.evidence.isEmpty { missing.append("evidence") }
        return "\(name) was dropped: missing \(missing.joined(separator: ", "))."
    }

    /// The last fenced block that looks like JSON.
    ///
    /// The last, not the first: a model that echoes the requested schema before
    /// answering would otherwise have its example harvested instead of its work.
    static func lastFencedJSONBlock(in text: String) -> String? {
        var blocks: [String] = []
        var remainder = text[...]

        while let open = remainder.range(of: "```") {
            let afterOpen = remainder[open.upperBound...]
            // Drop a language tag if there is one.
            let bodyStart = afterOpen.firstIndex(of: "\n").map(afterOpen.index(after:))
                ?? afterOpen.startIndex
            let body = afterOpen[bodyStart...]
            guard let close = body.range(of: "```") else { break }
            blocks.append(String(body[..<close.lowerBound]))
            remainder = body[close.upperBound...]
        }

        return blocks.reversed().first { block in
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("[") || trimmed.hasPrefix("{")
        }
    }
}
```

- [x] **Step 5: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter ProposalDecoderTests`
Expected: PASS, every case.

- [x] **Step 6: Run the whole suite and commit**

```bash
cd ElliotKit && swift test && cd ..
git add ElliotKit/Sources/ElliotModel/ProposalDecoder.swift \
        ElliotKit/Tests/ElliotModelTests/ProposalDecoderTests.swift \
        Fixtures/analysis
git commit -m "feat(model): harvest stories without throwing any of them away quietly

Same contract as the stream-json decoder: one malformed story costs one
story, not the run. Every discarded story leaves a sentence saying why,
because 'we found 8' and 'we found 12 and threw 4 away' are different
results and the reader should know which they are looking at.

The fenced-block fallback takes the LAST block, so a model that echoes
the requested schema before answering does not get its example harvested."
```

---

### Task 5: A run that has no card

**Files:**
- Modify: `ElliotKit/Sources/ElliotModel/SkillRun.swift:42-109`
- Modify: `ElliotKit/Sources/ElliotModel/SlashCommandBuilder.swift:14-28,61-84`
- Modify: `ElliotKit/Sources/ElliotEngine/Verifier.swift:17-30`
- Modify: `ElliotKit/Sources/ElliotEngine/RunScheduler.swift:21-26,71-84,178-208`
- Modify: `ElliotKit/Sources/ElliotEngine/Reconciler.swift:49-65`
- Modify: `ElliotKit/Sources/ElliotIPC/Protocol.swift:137-163`
- Modify: `ElliotKit/Sources/ElliotApp/AppModel.swift:177-199`
- Test: `ElliotKit/Tests/ElliotModelTests/AnalysisModelTests.swift` (add to the existing suite)

**Interfaces:**
- Consumes: `AnalysisAngle`, `AnalysisRunReport` from Task 1.
- Produces: `SkillKind.analyzeRepo`; `SkillKind.slashName: String?`; `SkillRun.cardID: UUID?`, `.analysisID: UUID?`, `.analysisAngle: AnalysisAngle?`, `.analysisReport: AnalysisRunReport?`, `.isAnalysis: Bool`; `SchedulerUpdate` cases carry `cardID: UUID?`.

**Why this shape:** an analysis run is an ordinary `SkillRun` so it inherits admission, streaming, the durable log, SIGTERM cancellation, the idle timeout and the launch sweep — all already written and tested. The alternative, a parallel `analysisRun` table, avoids the migration and duplicates four subsystems. The angle lives on the run because the window shows it per run ("run bugs · running") and because the dedupe key is `(repoID, angle)`.

- [x] **Step 1: Write the failing test**

Append to `ElliotKit/Tests/ElliotModelTests/AnalysisModelTests.swift`, inside the `AnalysisModelTests` suite:

```swift
    @Test("Exactly one of card or analysis owns a run")
    func aRunBelongsToOneThing() {
        let cardRun = SkillRun(
            cardID: UUID(), repoID: UUID(), kind: .createIssue, prompt: "x",
            cwd: "/tmp", logPath: "/tmp/a.ndjson", stderrPath: "/tmp/a.log", createdAt: Date()
        )
        #expect(cardRun.cardID != nil)
        #expect(cardRun.analysisID == nil)
        #expect(!cardRun.isAnalysis)

        let analysisRun = SkillRun(
            cardID: nil, repoID: UUID(), analysisID: UUID(), analysisAngle: .bugs,
            kind: .analyzeRepo, prompt: "x", cwd: "/tmp",
            logPath: "/tmp/b.ndjson", stderrPath: "/tmp/b.log", createdAt: Date()
        )
        #expect(analysisRun.cardID == nil)
        #expect(analysisRun.isAnalysis)
        #expect(analysisRun.analysisAngle == .bugs)
    }

    @Test("Only the three plugin skills have a slash name")
    func onlySkillsHaveSlashNames() {
        #expect(SkillKind.createIssue.slashName == "/ai-migration-kit:create-issue")
        #expect(SkillKind.implementIssue.slashName == "/ai-migration-kit:implement-issue")
        #expect(SkillKind.mergePR.slashName == "/ai-migration-kit:merge-pr")
        // There is no analyze-repo skill; that prompt is Elliot's own.
        #expect(SkillKind.analyzeRepo.slashName == nil)
    }
```

- [x] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter AnalysisModelTests`
Expected: FAIL — `type 'SkillKind' has no member 'analyzeRepo'`.

- [x] **Step 3: Widen `SkillKind` in `SlashCommandBuilder.swift`**

Replace the `SkillKind` declaration (lines 14-28) with:

```swift
public enum SkillKind: String, Codable, CaseIterable, Sendable, Hashable {
    case createIssue
    case implementIssue
    case mergePR
    /// Reading a repository through one lens. Not a plugin skill — see below.
    case analyzeRepo

    /// Plugin-qualified slash name, for the three kinds that *are* plugin
    /// skills. The CLI builds component ids as `"\(pluginName):\(name)"`.
    ///
    /// `.analyzeRepo` has none: there is no `analyze-repo` skill anywhere, that
    /// prompt is Elliot's own and is built by `AnalysisPromptBuilder`.
    public var slashName: String? {
        switch self {
        case .createIssue: "/ai-migration-kit:create-issue"
        case .implementIssue: "/ai-migration-kit:implement-issue"
        case .mergePR: "/ai-migration-kit:merge-pr"
        case .analyzeRepo: nil
        }
    }
}
```

Then rewrite `slashPrompt(for:)` (lines 61-84) so the optional is handled once instead of at every case:

```swift
    private static func slashPrompt(for action: TriggerAction) -> String {
        // A `TriggerAction` is by construction one of the three plugin skills,
        // so this is never nil on this path. Falling back rather than forcing
        // keeps the function total if that ever stops being true.
        guard let name = action.kind.slashName else { return naturalPrompt(for: action) }

        switch action {
        case .createIssue(let idea):
            // Free text; the skill infers scope from it. Flattened because the
            // whole prompt is one argv element and one logical line.
            return "\(name) \(idea.collapsedToSingleLine())"

        case .implementIssue(let n):
            // The skill resolves its argument with `grep -oE '[0-9]+' | head -1`.
            // Emit the number and nothing else — no title, no '#', no year.
            // `SlashCommandBuilderTests.firstDigitRunIsTheIssueNumber` guards this.
            return "\(name) \(n)"

        case .mergePR(let pr, let followUps):
            // The skill parses `--follow-up "<idea>"` out of the text, so quotes
            // are structural here and must be escaped inside the payload.
            let tail = followUps
                .map(sanitizeFollowUp)
                .filter { !$0.isEmpty }
                .map { #" --follow-up "\#($0)""# }
                .joined()
            return "\(name) \(pr)\(tail)"
        }
    }
```

- [x] **Step 4: Widen `SkillRun` in `SkillRun.swift`**

Change the four properties and the initialiser. Replace `public var cardID: UUID` with:

```swift
    /// The card this run works on. `nil` for an analysis run, which has no card
    /// — exactly one of `cardID` and `analysisID` is set.
    public var cardID: UUID?
```

Add after `repoID`:

```swift
    /// The analysis this run belongs to, when it is one.
    public var analysisID: UUID?
    /// Which lens this run reads through. On the run rather than only on the
    /// analysis because the window lists runs by angle, and because the
    /// scheduler's dedupe key is `(repoID, angle)`.
    public var analysisAngle: AnalysisAngle?
```

Add after `verifiedOutcome`:

```swift
    /// What an analysis run had to say about itself: where the stories were
    /// harvested from, what was dropped, and whether the working tree moved.
    /// `nil` for a card run.
    public var analysisReport: AnalysisRunReport?
```

Update the initialiser signature and body — `cardID: UUID?`, and three new defaulted parameters placed to keep every existing call site compiling:

```swift
    public init(
        id: UUID = UUID(),
        cardID: UUID?,
        repoID: UUID,
        analysisID: UUID? = nil,
        analysisAngle: AnalysisAngle? = nil,
        kind: SkillKind,
        prompt: String,
        argv: [String] = [],
        cwd: String,
        state: RunState = .queued,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        exitCode: Int32? = nil,
        logPath: String,
        stderrPath: String,
        resultText: String? = nil,
        totalCostUSD: Double? = nil,
        numTurns: Int? = nil,
        permissionDenials: [String] = [],
        verifiedOutcome: VerifiedOutcome? = nil,
        analysisReport: AnalysisRunReport? = nil,
        createdAt: Date
    ) {
```

Assign the three new properties in the body alongside the others, and add:

```swift
public extension SkillRun {
    var isAnalysis: Bool { kind == .analyzeRepo }
}
```

- [x] **Step 5: Make the call sites exhaustive again**

`Verifier.swift`, in `verify(run:card:repo:)`, add to the switch:

```swift
            case .analyzeRepo:
                // Unreachable: analysis runs are completed by ProposalHarvester,
                // and there is nothing on GitHub to check an opinion against.
                return .unverified(reason: "An analysis has no GitHub outcome to verify.")
```

`RunScheduler.swift`, in `SchedulerUpdate`, make the card optional in both cases that carry it:

```swift
public enum SchedulerUpdate: Sendable {
    case runStarted(runID: UUID, cardID: UUID?)
    case runOutput(runID: UUID, event: StreamEvent)
    case runStalled(runID: UUID, since: Date)
    case runFinished(runID: UUID, cardID: UUID?, state: RunState, outcome: VerifiedOutcome?)
}
```

In `canStart`, add the missing case (the real admission rules land in Task 8; this keeps the switch exhaustive):

```swift
        case .analyzeRepo:
            return true
```

In `finish`, guard the card lookup:

```swift
        var verified: VerifiedOutcome?
        if let cardID = run.cardID,
           let card = try? await store.card(id: cardID),
           let repo = try? await store.repo(id: run.repoID) {
```

`Reconciler.swift`, in `sweep`, guard the same lookup:

```swift
                if let cardID = run.cardID,
                   let card = try? await store.card(id: cardID),
                   let repo = try? await store.repo(id: run.repoID) {
```

`Protocol.swift`, `RunDTO.cardID` becomes `UUID?` (the property and the assignment in `init(run:)` need no other change).

`AppModel.swift`, in `apply(_:)`, the finish case:

```swift
        case .runFinished(let runID, let cardID, let state, _):
            var lines = liveLog[runID] ?? []
            lines.append("■ \(state.rawValue)")
            liveLog[runID] = lines
            if let cardID { Task { await self.refreshRuns(cardID: cardID) } }
```

- [x] **Step 6: Build, run the suite**

Run: `cd ElliotKit && swift build && swift test`
Expected: PASS. If the compiler reports a call site this plan did not list, fix it the same way — the change is mechanical, and `cardID` is only ever read to find a card.

- [x] **Step 7: Commit**

```bash
git add ElliotKit/Sources ElliotKit/Tests
git commit -m "feat(model): let a run belong to an analysis instead of a card

An analysis run has no card. Making cardID optional and adding the
analysis link is what lets it be an ordinary SkillRun — and so inherit
admission, streaming, the durable log, SIGTERM cancellation, the idle
timeout and the launch sweep, all already written and tested. A parallel
analysisRun table would have avoided one migration and duplicated four
subsystems.

slashName is now optional because there is no analyze-repo skill: that
prompt is Elliot's own. TriggerAction is untouched, so the rule engine
still knows exactly three transitions."
```

---

### Task 6: Migration v2 — the analysis tables

**Files:**
- Modify: `ElliotKit/Sources/ElliotStore/Migrations.swift`
- Modify: `ElliotKit/Sources/ElliotStore/Records.swift`
- Modify: `ElliotKit/Sources/ElliotStore/BoardStore.swift`
- Modify: `ElliotKit/Sources/ElliotStore/StoreLocation.swift`
- Test: `ElliotKit/Tests/ElliotStoreTests/AnalysisStoreTests.swift`

**Interfaces:**
- Consumes: `Analysis`, `StoryProposal`, `AnalysisAngle`, `ProposalStatus` from Task 1; the widened `SkillRun` from Task 5.
- Produces: `BoardStore.saveAnalysis(_:)`, `.analysis(id:)`, `.analyses(repoID:limit:)`, `.saveProposals(_:)`, `.saveProposal(_:)`, `.proposal(id:)`, `.proposals(analysisID:repoID:status:limit:)`, `.observeProposals(analysisID:)`, `.runs(analysisID:)`, `.activeAnalysisRuns(repoID:)`; `StoreLocation.analysisArtifactURL(analysisID:runID:)`.

**The one sharp edge:** SQLite cannot relax a `NOT NULL` in place, so `skillRun` is rebuilt. `ALTER TABLE … RENAME` keeps the old indexes attached under their original names, so the new indexes must be created **after** the old table is dropped or the names collide.

- [x] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotStoreTests/AnalysisStoreTests.swift`:

```swift
import ElliotModel
import Foundation
import GRDB
import Testing

@testable import ElliotStore

@Suite("Analysis store")
struct AnalysisStoreTests {

    private func seededStore() async throws -> (BoardStore, Repo) {
        let store = try BoardStore.inMemory()
        let repo = Repo(path: "/tmp/r", nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        try await store.saveRepo(repo)
        return (store, repo)
    }

    @Test("An analysis and its proposals round-trip")
    func roundTrip() async throws {
        let (store, repo) = try await seededStore()
        let analysis = Analysis(
            repoID: repo.id, angles: [.bugs, .quickWins],
            extraInstructions: "focus on ElliotProcess", maxStoriesPerAngle: 5,
            origin: .mcp(client: "claude-code"), createdAt: Date()
        )
        try await store.saveAnalysis(analysis)

        let loaded = try #require(try await store.analysis(id: analysis.id))
        #expect(loaded.angles == [.bugs, .quickWins])
        #expect(loaded.maxStoriesPerAngle == 5)
        #expect(loaded.origin == .mcp(client: "claude-code"))

        let proposal = StoryProposal(
            analysisID: analysis.id, runID: UUID(), repoID: repo.id, angle: .bugs,
            title: "Idle window leaks on cancellation",
            story: UserStory(role: "developer", want: "the idle task to stop", benefit: "no wakeups"),
            rationale: "The task is only cancelled on the happy path.",
            evidence: [Evidence(path: "Sources/ElliotProcess/ClaudeRunner.swift", line: 159, exists: true)],
            effort: .small,
            duplicateOf: .issue(number: 12, title: "Idle leak"),
            createdAt: Date()
        )
        try await store.saveProposals([proposal])

        let back = try #require(try await store.proposal(id: proposal.id))
        #expect(back.story.narrative.hasPrefix("As a developer"))
        #expect(back.evidence.first?.line == 159)
        #expect(back.duplicateOf == .issue(number: 12, title: "Idle leak"))
        #expect(back.status == .proposed)
    }

    @Test("Proposals filter by analysis and by status")
    func filtering() async throws {
        let (store, repo) = try await seededStore()
        let analysis = Analysis(repoID: repo.id, angles: [.bugs], createdAt: Date())
        try await store.saveAnalysis(analysis)

        func make(_ title: String, _ status: ProposalStatus) -> StoryProposal {
            StoryProposal(
                analysisID: analysis.id, runID: UUID(), repoID: repo.id, angle: .bugs,
                title: title,
                story: UserStory(role: "dev", want: "w", benefit: "b"),
                status: status, createdAt: Date()
            )
        }
        try await store.saveProposals([make("A", .proposed), make("B", .accepted), make("C", .rejected)])

        #expect(try await store.proposals(analysisID: analysis.id).count == 3)
        #expect(try await store.proposals(analysisID: analysis.id, status: .proposed).count == 1)
        #expect(try await store.proposals(repoID: repo.id, status: .accepted).map(\.title) == ["B"])
    }

    @Test("An analysis run stores its angle and no card")
    func analysisRunHasNoCard() async throws {
        let (store, repo) = try await seededStore()
        let analysis = Analysis(repoID: repo.id, angles: [.tests], createdAt: Date())
        try await store.saveAnalysis(analysis)

        let run = SkillRun(
            cardID: nil, repoID: repo.id, analysisID: analysis.id, analysisAngle: .tests,
            kind: .analyzeRepo, prompt: "…", cwd: repo.path,
            logPath: "/tmp/x.ndjson", stderrPath: "/tmp/x.log", createdAt: Date()
        )
        try await store.saveRun(run)

        let back = try #require(try await store.run(id: run.id))
        #expect(back.cardID == nil)
        #expect(back.analysisAngle == .tests)
        #expect(try await store.runs(analysisID: analysis.id).count == 1)
    }

    @Test("The report a run writes about itself survives a round trip")
    func reportRoundTrip() async throws {
        let (store, repo) = try await seededStore()
        let analysis = Analysis(repoID: repo.id, angles: [.bugs], createdAt: Date())
        try await store.saveAnalysis(analysis)

        var run = SkillRun(
            cardID: nil, repoID: repo.id, analysisID: analysis.id, analysisAngle: .bugs,
            kind: .analyzeRepo, prompt: "…", cwd: repo.path,
            logPath: "/tmp/y.ndjson", stderrPath: "/tmp/y.log", createdAt: Date()
        )
        run.analysisReport = AnalysisRunReport(
            harvestSource: .resultText, kept: 3, dropped: ["“X” was dropped: missing benefit."],
            workingTreeChanged: true, workingTreeDiff: " M Sources/A.swift"
        )
        try await store.saveRun(run)

        let back = try #require(try await store.run(id: run.id)?.analysisReport)
        #expect(back.harvestSource == .resultText)
        #expect(back.workingTreeChanged)
        #expect(back.dropped.count == 1)
    }

    @Test("Deleting a repository takes its analyses and proposals with it")
    func cascade() async throws {
        let (store, repo) = try await seededStore()
        let analysis = Analysis(repoID: repo.id, angles: [.bugs], createdAt: Date())
        try await store.saveAnalysis(analysis)
        try await store.saveProposals([StoryProposal(
            analysisID: analysis.id, runID: UUID(), repoID: repo.id, angle: .bugs, title: "A",
            story: UserStory(role: "dev", want: "w", benefit: "b"), createdAt: Date()
        )])

        try await store.deleteRepo(id: repo.id)
        #expect(try await store.analysis(id: analysis.id) == nil)
        #expect(try await store.proposals(analysisID: analysis.id).isEmpty)
    }

    /// The migration is the one part of this feature that can lose data.
    @Test("Migrating a populated v1 database loses nothing")
    func migrationPreservesRows() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elliot-migration-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        // Build a v1 database by running only the first migration.
        var v1 = DatabaseMigrator()
        v1.registerMigration("v1_initial", migrate: Migrations.v1Initial)
        let pool = try DatabasePool(path: url.path)
        try v1.migrate(pool)

        let repoID = UUID(), cardID = UUID(), runID = UUID()
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO "repo" VALUES (?,?,?,?,?,?,?,1)
                    """,
                arguments: [repoID.databaseKey, "/tmp/r", "phmatray/Elliot", "main",
                            "Elliot", "bypassPermissions", "[]"]
            )
            try db.execute(
                sql: """
                    INSERT INTO "card" ("id","repoID","title","body","column","orderIndex",
                                        "columnEnteredAt","createdAt","updatedAt")
                    VALUES (?,?,?,?,?,?,?,?,?)
                    """,
                arguments: [cardID.databaseKey, repoID.databaseKey, "Dark mode", "",
                            "backlog", 1024.0, Date(), Date(), Date()]
            )
            try db.execute(
                sql: """
                    INSERT INTO "skillRun" ("id","cardID","repoID","kind","prompt","argv","cwd",
                                            "state","logPath","stderrPath","permissionDenials","createdAt")
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                    """,
                arguments: [runID.databaseKey, cardID.databaseKey, repoID.databaseKey,
                            "createIssue", "/ai-migration-kit:create-issue x", "[]", "/tmp/r",
                            "succeeded", "/tmp/a.ndjson", "/tmp/a.log", "[]", Date()]
            )
        }
        try await pool.close()

        // Now open it the way the app does, which runs every migration.
        let store = try BoardStore.open(at: url)
        #expect(try await store.repo(id: repoID) != nil)
        #expect(try await store.card(id: cardID)?.title == "Dark mode")
        let run = try #require(try await store.run(id: runID))
        #expect(run.cardID == cardID)
        #expect(run.kind == .createIssue)
        #expect(run.analysisID == nil)
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter AnalysisStoreTests`
Expected: FAIL — `value of type 'BoardStore' has no member 'saveAnalysis'`, and `Migrations` has no member `v1Initial`.

- [x] **Step 3: Rewrite `Migrations.swift`**

Extract the existing v1 body into a named function so the test can build a v1 database, then add v2:

```swift
import Foundation
import GRDB

enum Migrations {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_initial", migrate: v1Initial)
        // Deferred because skillRun is rebuilt: its rows reference card and repo
        // while the table is briefly named skillRun_old.
        migrator.registerMigration("v2_analysis", foreignKeyChecks: .deferred, migrate: v2Analysis)
        return migrator
    }

    /// The original schema. Named so a test can build a v1 database and prove
    /// the upgrade to v2 loses nothing.
    static func v1Initial(_ db: Database) throws {
        // ← move the entire existing body of the "v1_initial" migration here,
        //   unchanged.
    }

    static func v2Analysis(_ db: Database) throws {
        try db.create(table: "analysis") { t in
            t.primaryKey("id", .text)
            t.column("repoID", .text).notNull()
                .references("repo", onDelete: .cascade)
            t.column("angles", .text).notNull()              // JSON array
            t.column("extraInstructions", .text).notNull()
            t.column("maxStoriesPerAngle", .integer).notNull()
            t.column("origin", .text).notNull()              // JSON object
            t.column("createdAt", .datetime).notNull()
        }
        try db.create(index: "analysis_on_repo_created", on: "analysis", columns: ["repoID", "createdAt"])

        try db.create(table: "storyProposal") { t in
            t.primaryKey("id", .text)
            t.column("analysisID", .text).notNull()
                .references("analysis", onDelete: .cascade)
            t.column("runID", .text).notNull()
            t.column("repoID", .text).notNull()
                .references("repo", onDelete: .cascade)
            t.column("angle", .text).notNull()
            t.column("title", .text).notNull()
            t.column("story", .text).notNull()               // JSON object
            t.column("rationale", .text).notNull()
            t.column("evidence", .text).notNull()            // JSON array
            t.column("effort", .text).notNull()
            t.column("status", .text).notNull()
            t.column("acceptedCardID", .text)
            t.column("duplicateOf", .text)                   // JSON object, null when none
            t.column("createdAt", .datetime).notNull()
        }
        try db.create(
            index: "storyProposal_on_analysis_status",
            on: "storyProposal", columns: ["analysisID", "status"]
        )
        try db.create(
            index: "storyProposal_on_repo_status",
            on: "storyProposal", columns: ["repoID", "status"]
        )

        // SQLite cannot relax a NOT NULL in place, so the table is rebuilt.
        // A renamed table keeps its indexes under their original names, so the
        // new ones can only be created after the old table is dropped.
        try db.rename(table: "skillRun", to: "skillRun_old")
        try db.create(table: "skillRun") { t in
            t.primaryKey("id", .text)
            // Nullable now: an analysis run has no card.
            t.column("cardID", .text)
                .references("card", onDelete: .cascade)
            t.column("repoID", .text).notNull()
                .references("repo", onDelete: .cascade)
            t.column("analysisID", .text)
                .references("analysis", onDelete: .cascade)
            t.column("analysisAngle", .text)
            t.column("kind", .text).notNull()
            t.column("prompt", .text).notNull()
            t.column("argv", .text).notNull()
            t.column("cwd", .text).notNull()
            t.column("state", .text).notNull()
            t.column("startedAt", .datetime)
            t.column("endedAt", .datetime)
            t.column("exitCode", .integer)
            t.column("logPath", .text).notNull()
            t.column("stderrPath", .text).notNull()
            t.column("resultText", .text)
            t.column("totalCostUSD", .double)
            t.column("numTurns", .integer)
            t.column("permissionDenials", .text).notNull()
            t.column("verifiedOutcome", .text)
            t.column("analysisReport", .text)                // JSON object
            t.column("createdAt", .datetime).notNull()
        }
        try db.execute(sql: """
            INSERT INTO "skillRun" (
              "id","cardID","repoID","analysisID","analysisAngle","kind","prompt","argv","cwd",
              "state","startedAt","endedAt","exitCode","logPath","stderrPath","resultText",
              "totalCostUSD","numTurns","permissionDenials","verifiedOutcome","analysisReport",
              "createdAt"
            )
            SELECT
              "id","cardID","repoID",NULL,NULL,"kind","prompt","argv","cwd",
              "state","startedAt","endedAt","exitCode","logPath","stderrPath","resultText",
              "totalCostUSD","numTurns","permissionDenials","verifiedOutcome",NULL,
              "createdAt"
            FROM "skillRun_old"
            """)
        try db.drop(table: "skillRun_old")

        try db.create(index: "skillRun_on_card_created", on: "skillRun", columns: ["cardID", "createdAt"])
        try db.create(index: "skillRun_on_state", on: "skillRun", columns: ["state"])
        try db.create(index: "skillRun_on_analysis", on: "skillRun", columns: ["analysisID"])
    }
}
```

- [x] **Step 4: Add the records in `Records.swift`**

```swift
extension Analysis: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "analysis"
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .uppercaseString
    }

    public enum Columns {
        public static let repoID = GRDB.Column("repoID")
        public static let createdAt = GRDB.Column("createdAt")
    }
}

extension StoryProposal: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "storyProposal"
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .uppercaseString
    }

    public enum Columns {
        public static let analysisID = GRDB.Column("analysisID")
        public static let repoID = GRDB.Column("repoID")
        public static let status = GRDB.Column("status")
        public static let createdAt = GRDB.Column("createdAt")
    }
}
```

Add `analysisID` to `SkillRun.Columns`:

```swift
        public static let analysisID = GRDB.Column("analysisID")
```

- [x] **Step 5: Add the store methods in `BoardStore.swift`**

Insert a new `// MARK: - Analyses` section after the runs section:

```swift
    // MARK: - Analyses

    public func saveAnalysis(_ analysis: Analysis) async throws {
        try await requireWriter().write { db in try analysis.save(db) }
    }

    public func analysis(id: UUID) async throws -> Analysis? {
        try await reader.read { db in try Analysis.fetchOne(db, key: id.databaseKey) }
    }

    public func analyses(repoID: UUID? = nil, limit: Int = 50) async throws -> [Analysis] {
        try await reader.read { db in
            var request = Analysis.all()
            if let repoID {
                request = request.filter(Analysis.Columns.repoID == repoID.databaseKey)
            }
            return try request.order(Analysis.Columns.createdAt.desc).limit(limit).fetchAll(db)
        }
    }

    /// Every run of one analysis, oldest first — the order the window lists them.
    public func runs(analysisID: UUID) async throws -> [SkillRun] {
        try await reader.read { db in
            try SkillRun
                .filter(SkillRun.Columns.analysisID == analysisID.databaseKey)
                .order(SkillRun.Columns.createdAt)
                .fetchAll(db)
        }
    }

    /// Analysis runs still in flight for a repo. The dedupe key `(repoID, angle)`
    /// is checked against this.
    public func activeAnalysisRuns(repoID: UUID) async throws -> [SkillRun] {
        try await reader.read { db in
            try SkillRun
                .filter(SkillRun.Columns.repoID == repoID.databaseKey)
                .filter(SkillRun.Columns.analysisID != nil)
                .filter(Self.activeStates.contains(SkillRun.Columns.state))
                .fetchAll(db)
        }
    }

    // MARK: - Proposals

    public func saveProposals(_ proposals: [StoryProposal]) async throws {
        try await requireWriter().write { db in
            for proposal in proposals { try proposal.save(db) }
        }
    }

    public func saveProposal(_ proposal: StoryProposal) async throws {
        try await saveProposals([proposal])
    }

    public func proposal(id: UUID) async throws -> StoryProposal? {
        try await reader.read { db in try StoryProposal.fetchOne(db, key: id.databaseKey) }
    }

    public func proposals(
        analysisID: UUID? = nil,
        repoID: UUID? = nil,
        status: ProposalStatus? = nil,
        limit: Int = 500
    ) async throws -> [StoryProposal] {
        try await reader.read { db in
            try Self.proposalQuery(analysisID: analysisID, repoID: repoID, status: status)
                .limit(limit)
                .fetchAll(db)
        }
    }

    private static func proposalQuery(
        analysisID: UUID?, repoID: UUID?, status: ProposalStatus?
    ) -> QueryInterfaceRequest<StoryProposal> {
        var request = StoryProposal.all()
        if let analysisID {
            request = request.filter(StoryProposal.Columns.analysisID == analysisID.databaseKey)
        }
        if let repoID {
            request = request.filter(StoryProposal.Columns.repoID == repoID.databaseKey)
        }
        if let status {
            request = request.filter(StoryProposal.Columns.status == status.rawValue)
        }
        return request.order(StoryProposal.Columns.createdAt)
    }

    /// Live proposals for the analysis window: they arrive run by run, so the
    /// list fills in as each angle lands rather than after the last one.
    public func observeProposals(analysisID: UUID) -> AsyncValueObservation<[StoryProposal]> {
        ValueObservation
            .tracking { db in
                try Self.proposalQuery(analysisID: analysisID, repoID: nil, status: nil).fetchAll(db)
            }
            .removeDuplicates()
            .values(in: reader)
    }
```

- [x] **Step 6: Add the artifact path in `StoreLocation.swift`**

```swift
    /// One directory per analysis run, holding the `stories.json` the run was
    /// told to write. Kept beside the run's log so a harvest can be repeated
    /// from disk without spawning anything.
    public static var analysesDirectory: URL {
        home.appendingPathComponent("analyses", isDirectory: true)
    }

    public static func analysisRunDirectory(analysisID: UUID, runID: UUID) -> URL {
        analysesDirectory
            .appendingPathComponent(analysisID.uuidString, isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
    }

    public static func analysisArtifactURL(analysisID: UUID, runID: UUID) -> URL {
        analysisRunDirectory(analysisID: analysisID, runID: runID)
            .appendingPathComponent("stories.json")
    }
```

And add `analysesDirectory` to the loop in `ensureDirectories()`:

```swift
        for url in [home, runsDirectory, analysesDirectory] {
```

- [x] **Step 7: Run the tests**

Run: `cd ElliotKit && swift test --filter AnalysisStoreTests`
Expected: PASS, including `migrationPreservesRows`.

If `activeAnalysisRuns` fails to compile on `!= nil`, use the explicit form: `.filter(sql: #""analysisID" IS NOT NULL"#)`.

- [x] **Step 8: Run the whole suite and commit**

```bash
cd ElliotKit && swift test && cd ..
git add ElliotKit/Sources/ElliotStore ElliotKit/Tests/ElliotStoreTests
git commit -m "feat(store): analysis tables, and a skillRun that may have no card

SQLite cannot relax a NOT NULL in place, so skillRun is rebuilt. A
renamed table keeps its indexes under their original names, which is why
the new indexes are created only after the old table is dropped.

The migration is the one part of this feature that can lose data, so the
test builds a populated v1 database and asserts the upgrade keeps every
row."
```

---

### Task 7: The proposal harvester

**Files:**
- Create: `ElliotKit/Sources/ElliotEngine/ProposalHarvester.swift`
- Modify: `ElliotKit/Sources/ElliotModel/GHPayloads.swift:6-20` (add `GHIssue.isOpen`)
- Test: `ElliotKit/Tests/ElliotEngineTests/ProposalHarvesterTests.swift`

**Interfaces:**
- Consumes: `ProposalDecoder`, `Evidence`, `StoryProposal`, `AnalysisRunReport`, `TextSimilarity` (Tasks 1–4); `BoardStore.saveProposals(_:)`, `.cards(repoID:column:)` (Task 6); `GHClient.issues(repo:limit:)`.
- Produces: `ProposalHarvester(store:gh:)`, `.harvest(run:analysis:repo:artifactURL:) async -> AnalysisRunReport`.

**Note on `artifactURL`:** it is passed in rather than computed, so a test can point at a temp file without setting `ELLIOT_HOME` for the whole process. The scheduler passes `StoreLocation.analysisArtifactURL(analysisID:runID:)` — the same path the prompt announced.

- [x] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotEngineTests/ProposalHarvesterTests.swift`:

```swift
import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine

@Suite("Proposal harvester")
struct ProposalHarvesterTests {

    /// A throwaway repository with two real files, so evidence resolution has
    /// something true and something false to distinguish.
    private struct Fixture {
        var store: BoardStore
        var repo: Repo
        var analysis: Analysis
        var run: SkillRun
        var artifactURL: URL
        var root: URL

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    private func makeFixture() async throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elliot-harvest-\(UUID().uuidString)", isDirectory: true)
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "// real".write(to: sources.appendingPathComponent("Real.swift"), atomically: true, encoding: .utf8)

        let store = try BoardStore.inMemory()
        let repo = Repo(path: root.path, nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        try await store.saveRepo(repo)

        let analysis = Analysis(repoID: repo.id, angles: [.bugs], maxStoriesPerAngle: 8, createdAt: Date())
        try await store.saveAnalysis(analysis)

        let run = SkillRun(
            cardID: nil, repoID: repo.id, analysisID: analysis.id, analysisAngle: .bugs,
            kind: .analyzeRepo, prompt: "…", cwd: repo.path,
            logPath: root.appendingPathComponent("run.ndjson").path,
            stderrPath: root.appendingPathComponent("run.log").path,
            createdAt: Date()
        )
        try await store.saveRun(run)

        return Fixture(
            store: store, repo: repo, analysis: analysis, run: run,
            artifactURL: root.appendingPathComponent("stories.json"),
            root: root
        )
    }

    /// `gh` unreachable, so duplicate hints come from the board alone — which is
    /// also the honest default in these tests.
    private func makeHarvester(_ fixture: Fixture) -> ProposalHarvester {
        let config = ToolConfig(
            claudePath: "/usr/bin/false", ghPath: "/usr/bin/false",
            gitPath: "/usr/bin/false", environment: [:]
        )
        return ProposalHarvester(store: fixture.store, gh: GHClient(config: config))
    }

    @Test("A harvested artifact becomes proposals, with evidence resolved")
    func harvestsFromArtifact() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        try """
        [
          {"title":"Grounded","role":"dev","want":"w","benefit":"b",
           "evidence":["Sources/Real.swift:3"],"effort":"small"},
          {"title":"Invented","role":"dev","want":"w","benefit":"b",
           "evidence":["Sources/Nowhere.swift:9"],"effort":"large"}
        ]
        """.write(to: fixture.artifactURL, atomically: true, encoding: .utf8)

        let report = await makeHarvester(fixture).harvest(
            run: fixture.run, analysis: fixture.analysis,
            repo: fixture.repo, artifactURL: fixture.artifactURL
        )

        #expect(report.harvestSource == .artifact)
        #expect(report.kept == 2)
        #expect(report.dropped.isEmpty)

        let proposals = try await fixture.store.proposals(analysisID: fixture.analysis.id)
        #expect(proposals.count == 2)

        let grounded = try #require(proposals.first { $0.title == "Grounded" })
        #expect(grounded.isGrounded)
        #expect(grounded.evidence.first?.line == 3)
        #expect(grounded.effort == .small)
        #expect(grounded.angle == .bugs)
        #expect(grounded.runID == fixture.run.id)

        let invented = try #require(proposals.first { $0.title == "Invented" })
        #expect(!invented.isGrounded)
    }

    @Test("With no artifact the closing message is tried, and the source says so")
    func fallsBackToResultText() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        var run = fixture.run
        run.resultText = """
            Here is what I found:

            ```json
            [{"title":"From prose","role":"dev","want":"w","benefit":"b",
              "evidence":["Sources/Real.swift"]}]
            ```
            """
        try await fixture.store.saveRun(run)

        let report = await makeHarvester(fixture).harvest(
            run: run, analysis: fixture.analysis,
            repo: fixture.repo, artifactURL: fixture.artifactURL
        )

        #expect(report.harvestSource == .resultText)
        #expect(report.kept == 1)
        let proposals = try await fixture.store.proposals(analysisID: fixture.analysis.id)
        #expect(proposals.map(\.title) == ["From prose"])
    }

    @Test("Nothing anywhere is reported as nothing, not as a crash")
    func nothingHarvested() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        let report = await makeHarvester(fixture).harvest(
            run: fixture.run, analysis: fixture.analysis,
            repo: fixture.repo, artifactURL: fixture.artifactURL
        )
        #expect(report.harvestSource == .none)
        #expect(report.kept == 0)
        #expect(!report.dropped.isEmpty)
    }

    @Test("A story that matches a card on the board is flagged, not removed")
    func duplicateOfACardIsHinted() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        let existing = Card(
            repoID: fixture.repo.id, title: "Cache the login shell environment",
            columnEnteredAt: Date(), createdAt: Date(), updatedAt: Date()
        )
        try await fixture.store.saveCard(existing)

        try """
        [{"title":"Cache the login shell environment at startup","role":"dev",
          "want":"w","benefit":"b","evidence":["Sources/Real.swift:1"]}]
        """.write(to: fixture.artifactURL, atomically: true, encoding: .utf8)

        _ = await makeHarvester(fixture).harvest(
            run: fixture.run, analysis: fixture.analysis,
            repo: fixture.repo, artifactURL: fixture.artifactURL
        )

        let proposal = try #require(try await fixture.store.proposals(analysisID: fixture.analysis.id).first)
        // Flagged, never dropped: skipping a near-duplicate is the reader's call.
        #expect(proposal.status == .proposed)
        guard case .card(_, let title)? = proposal.duplicateOf else {
            Issue.record("expected a card duplicate hint, got \(String(describing: proposal.duplicateOf))")
            return
        }
        #expect(title == "Cache the login shell environment")
    }

    @Test("Dropped stories keep their reasons in the report")
    func droppedReasonsSurvive() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }

        try """
        [{"title":"No benefit","role":"dev","want":"w","evidence":["Sources/Real.swift:1"]}]
        """.write(to: fixture.artifactURL, atomically: true, encoding: .utf8)

        let report = await makeHarvester(fixture).harvest(
            run: fixture.run, analysis: fixture.analysis,
            repo: fixture.repo, artifactURL: fixture.artifactURL
        )
        #expect(report.kept == 0)
        #expect(report.dropped.contains { $0.contains("benefit") })
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter ProposalHarvesterTests`
Expected: FAIL — `cannot find 'ProposalHarvester' in scope`.

- [x] **Step 3: Add `GHIssue.isOpen` in `GHPayloads.swift`**

Inside `GHIssue`, after the initialiser:

```swift
    public var isOpen: Bool { (state ?? "OPEN").uppercased() == "OPEN" }
```

- [x] **Step 4: Write `ProposalHarvester.swift`**

```swift
import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation

/// Turns a finished analysis run into proposals.
///
/// This is the analysis counterpart of `Verifier`, and it answers the same
/// question in a place where `gh` cannot: what did this run actually produce?
/// There is no external authority on whether a story is a good idea, so the
/// artifact is the fact — a file the run was told to write, read from disk,
/// rather than a paragraph read out of its closing message.
public struct ProposalHarvester: Sendable {
    private let store: BoardStore
    private let gh: GHClient

    public init(store: BoardStore, gh: GHClient) {
        self.store = store
        self.gh = gh
    }

    public func harvest(
        run: SkillRun,
        analysis: Analysis,
        repo: Repo,
        artifactURL: URL
    ) async -> AnalysisRunReport {
        let (harvest, source) = read(artifactURL: artifactURL, run: run, cap: analysis.maxStoriesPerAngle)

        guard !harvest.stories.isEmpty else {
            return AnalysisRunReport(harvestSource: source, kept: 0, dropped: harvest.dropped)
        }

        let existing = await existingTitles(repo: repo)
        let now = Date()
        let proposals = harvest.stories.map { story in
            StoryProposal(
                analysisID: analysis.id,
                runID: run.id,
                repoID: repo.id,
                angle: run.analysisAngle ?? analysis.angles.first ?? .bugs,
                title: story.title.trimmed(),
                story: story.story,
                rationale: story.rationale.trimmed(),
                evidence: resolve(story.evidence, repoPath: repo.path),
                effort: Effort.parse(story.effort),
                duplicateOf: hint(for: story.title, among: existing),
                createdAt: now
            )
        }

        do {
            try await store.saveProposals(proposals)
        } catch {
            return AnalysisRunReport(
                harvestSource: source,
                kept: 0,
                dropped: harvest.dropped + ["The proposals could not be saved: \(error.localizedDescription)"]
            )
        }

        return AnalysisRunReport(
            harvestSource: source, kept: proposals.count, dropped: harvest.dropped
        )
    }

    // MARK: - Reading

    /// The artifact first; the closing message only if there is no artifact to
    /// read. Which one answered is recorded, because "the model wrote the file"
    /// and "the model talked and we salvaged it" are different situations.
    private func read(
        artifactURL: URL, run: SkillRun, cap: Int
    ) -> (ProposalDecoder.Harvest, AnalysisRunReport.HarvestSource) {
        if let data = try? Data(contentsOf: artifactURL), !data.isEmpty {
            let harvest = ProposalDecoder.decode(artifact: data, maxStories: cap)
            if !harvest.stories.isEmpty { return (harvest, .artifact) }

            // The file was there and useless. Try the message, but keep the
            // artifact's complaints so the reader sees both failures.
            let fallback = ProposalDecoder.decode(resultText: run.resultText ?? "", maxStories: cap)
            if !fallback.stories.isEmpty {
                return (
                    ProposalDecoder.Harvest(
                        stories: fallback.stories, dropped: harvest.dropped + fallback.dropped
                    ),
                    .resultText
                )
            }
            return (
                ProposalDecoder.Harvest(dropped: harvest.dropped + fallback.dropped), .none
            )
        }

        let fallback = ProposalDecoder.decode(resultText: run.resultText ?? "", maxStories: cap)
        let dropped = ["No artifact was written at \(artifactURL.path)."] + fallback.dropped
        if fallback.stories.isEmpty {
            return (ProposalDecoder.Harvest(dropped: dropped), .none)
        }
        return (ProposalDecoder.Harvest(stories: fallback.stories, dropped: dropped), .resultText)
    }

    // MARK: - Evidence

    /// Resolves each citation against the repository root.
    ///
    /// A missing file does not disqualify a proposal — it marks it, and the
    /// window strikes it through. It is the fastest signal that a story was
    /// invented rather than found.
    private func resolve(_ raw: [String], repoPath: String) -> [Evidence] {
        let root = URL(fileURLWithPath: repoPath).standardizedFileURL
        return raw.compactMap { citation in
            guard let parsed = Evidence.parse(citation) else { return nil }
            let resolved = root.appendingPathComponent(parsed.path).standardizedFileURL
            // A citation must stay inside the repository: "../../etc/passwd"
            // is not evidence about this codebase.
            let inside = resolved.path.hasPrefix(root.path)
            return Evidence(
                path: parsed.path,
                line: parsed.line,
                exists: inside && FileManager.default.fileExists(atPath: resolved.path)
            )
        }
    }

    // MARK: - Duplicates

    private func existingTitles(repo: Repo) async -> [DuplicateHint] {
        var hints: [DuplicateHint] = []
        for card in (try? await store.cards(repoID: repo.id)) ?? [] {
            let title = card.displayTitle
            if !title.isEmpty { hints.append(.card(id: card.id, title: title)) }
        }
        // gh is best-effort here: a duplicate hint is a courtesy, and losing it
        // must not lose the proposals.
        for issue in (try? await gh.issues(repo: repo.nameWithOwner, limit: 100)) ?? []
        where issue.isOpen {
            hints.append(.issue(number: issue.number, title: issue.title))
        }
        return hints
    }

    private func hint(for title: String, among candidates: [DuplicateHint]) -> DuplicateHint? {
        let titles = candidates.map { hint -> String in
            switch hint {
            case .card(_, let title): title
            case .issue(_, let title): title
            }
        }
        guard let match = TextSimilarity.bestMatch(for: title, among: titles) else { return nil }
        return candidates[match.index]
    }
}
```

- [x] **Step 5: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter ProposalHarvesterTests`
Expected: PASS, all five.

- [x] **Step 6: Run the whole suite and commit**

```bash
cd ElliotKit && swift test && cd ..
git add ElliotKit/Sources/ElliotEngine/ProposalHarvester.swift \
        ElliotKit/Sources/ElliotModel/GHPayloads.swift \
        ElliotKit/Tests/ElliotEngineTests/ProposalHarvesterTests.swift
git commit -m "feat(engine): harvest proposals, and resolve what they claim

The analysis counterpart of Verifier, answering the same question where
gh cannot: what did this run actually produce? There is no authority on
whether a story is a good idea, so the artifact is the fact.

Evidence is resolved against the repository root and confined to it —
'../../etc/passwd' is not evidence about this codebase. A missing file
marks a proposal rather than removing it, because that mark is the
fastest way to see a story that was invented rather than found."
```

---

### Task 8: Scheduling an analysis, and the git sentinel

**Files:**
- Modify: `ElliotKit/Sources/ElliotEngine/RunScheduler.swift`
- Modify: `ElliotKit/Sources/ElliotEngine/Reconciler.swift:49-65`
- Modify: `ElliotKit/Sources/ElliotProcess/GHClient.swift:149-152` (`GitClient.porcelainStatus`)
- Test: `ElliotKit/Tests/ElliotEngineTests/AnalysisSchedulingTests.swift`

**Interfaces:**
- Consumes: `ProposalHarvester` (Task 7), `BoardStore.analysis(id:)` (Task 6).
- Produces: `RunScheduler.init(store:toolConfig:verifier:harvester:maxConcurrent:maxConcurrentAnalyses:)` — `harvester` and `maxConcurrentAnalyses` defaulted so every existing call site still compiles; `GitClient.porcelainStatus(cwd:) async -> String`.

**The admission rules, stated once:**

| In flight in the same repo | Analysis admitted? | Why |
|---|---|---|
| `mergePR` | no | it rewrites `main`, removes worktrees and deletes branches — a reader would see a moving target, and the sentinel would fire on someone else's work |
| `implementIssue` | yes | it works in a worktree, not the main checkout |
| `createIssue` | yes | it does not touch the tree |
| another analysis | yes | two readers |

Analysis runs get **their own lane** (cap 3) because the global cap of 2 exists to keep two *builds* out of one `.build/`, and an analysis compiles nothing. The reverse direction needs no new rule: `mergePR` already requires `sameRepo.isEmpty`, so it waits for a running analysis for free.

- [x] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotEngineTests/AnalysisSchedulingTests.swift`:

```swift
import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine

@Suite("Analysis scheduling")
struct AnalysisSchedulingTests {

    private func makeScheduler() throws -> (RunScheduler, Repo) {
        let store = try BoardStore.inMemory()
        let config = ToolConfig(
            claudePath: "/usr/bin/false", ghPath: "/usr/bin/false",
            gitPath: "/usr/bin/false", environment: [:]
        )
        let scheduler = RunScheduler(
            store: store, toolConfig: config, verifier: Verifier(gh: .init(config: config))
        )
        let repo = Repo(path: "/tmp/r", nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        return (scheduler, repo)
    }

    private func run(_ kind: SkillKind, repoID: UUID, angle: AnalysisAngle? = nil) -> SkillRun {
        SkillRun(
            cardID: kind == .analyzeRepo ? nil : UUID(),
            repoID: repoID,
            analysisID: kind == .analyzeRepo ? UUID() : nil,
            analysisAngle: angle,
            kind: kind, prompt: "…", cwd: "/tmp/r",
            logPath: "/tmp/a.ndjson", stderrPath: "/tmp/a.log", createdAt: Date()
        )
    }

    @Test("An analysis waits for a merge in the same repo, and nothing else",
          arguments: [(SkillKind.mergePR, false), (.implementIssue, true), (.createIssue, true), (.analyzeRepo, true)])
    func analysisAdmission(inFlight: SkillKind, admitted: Bool) async throws {
        let (scheduler, repo) = try makeScheduler()
        await scheduler.testOnlyMarkInFlight(run(inFlight, repoID: repo.id))
        let candidate = run(.analyzeRepo, repoID: repo.id, angle: .bugs)
        #expect(await scheduler.canStart(candidate) == admitted)
    }

    @Test("An analysis in another repo never blocks anything")
    func otherReposAreIrrelevant() async throws {
        let (scheduler, repo) = try makeScheduler()
        await scheduler.testOnlyMarkInFlight(run(.mergePR, repoID: UUID()))
        #expect(await scheduler.canStart(run(.analyzeRepo, repoID: repo.id, angle: .bugs)))
    }

    /// The cap of 2 exists so two builds do not share one .build/. An analysis
    /// compiles nothing, so it must not consume that budget.
    @Test("Analyses do not compete with the runs that write")
    func analysesHaveTheirOwnLane() async throws {
        let (scheduler, repo) = try makeScheduler()
        await scheduler.testOnlyMarkInFlight(run(.analyzeRepo, repoID: repo.id, angle: .bugs))
        await scheduler.testOnlyMarkInFlight(run(.analyzeRepo, repoID: repo.id, angle: .tests))
        // Two analyses in flight, and an implement-issue can still start.
        #expect(await scheduler.canStart(run(.implementIssue, repoID: repo.id)))
        // A third analysis fits; a fourth does not.
        #expect(await scheduler.canStart(run(.analyzeRepo, repoID: repo.id, angle: .features)))
        await scheduler.testOnlyMarkInFlight(run(.analyzeRepo, repoID: repo.id, angle: .features))
        #expect(await scheduler.canStart(run(.analyzeRepo, repoID: repo.id, angle: .docsAndDX)) == false)
    }

    @Test("A merge still waits for a running analysis, without a new rule")
    func mergeWaitsForAnalysis() async throws {
        let (scheduler, repo) = try makeScheduler()
        await scheduler.testOnlyMarkInFlight(run(.analyzeRepo, repoID: repo.id, angle: .bugs))
        #expect(await scheduler.canStart(run(.mergePR, repoID: repo.id)) == false)
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter AnalysisSchedulingTests`
Expected: FAIL — the lane test fails because analyses currently consume `maxConcurrent`.

- [x] **Step 3: Rewrite admission in `RunScheduler.swift`**

Add the stored properties beside `maxConcurrent`:

```swift
    private let maxConcurrentAnalyses: Int
    private let harvester: ProposalHarvester
    /// `git status --porcelain` taken just before each analysis spawned, keyed
    /// by run. In memory only: if the app dies mid-run the baseline is gone and
    /// the sweep reports the sentinel as unchecked rather than guessing.
    private var treeBaselines: [UUID: String] = [:]
    private let git: GitClient
```

Extend the initialiser:

```swift
    public init(
        store: BoardStore,
        toolConfig: ToolConfig,
        verifier: Verifier,
        harvester: ProposalHarvester? = nil,
        maxConcurrent: Int = 2,
        maxConcurrentAnalyses: Int = 3
    ) {
        self.store = store
        self.toolConfig = toolConfig
        self.verifier = verifier
        self.harvester = harvester ?? ProposalHarvester(store: store, gh: GHClient(config: toolConfig))
        self.maxConcurrent = maxConcurrent
        self.maxConcurrentAnalyses = maxConcurrentAnalyses
        self.git = GitClient(config: toolConfig)
        …
    }
```

Replace `canStart`:

```swift
    /// Whether a run may start now, given what is already going.
    ///
    /// Worktrees isolate git, so two `implement-issue` runs in one repo are
    /// safe. Two `merge-pr` runs are not — each merges to `main`, removes a
    /// worktree and deletes a branch. Two `create-issue` runs would each do
    /// duplicate detection against a repo the other is about to change.
    ///
    /// An analysis only reads, but it reads the working tree, so it must not
    /// overlap a merge in the same repo: it would see a moving target, and the
    /// git sentinel would fire on someone else's work. It gets its own lane
    /// because the cap below exists to keep two *builds* out of one `.build/`,
    /// and an analysis builds nothing.
    func canStart(_ run: SkillRun) -> Bool {
        let sameRepo = inFlight.values.filter { $0.repoID == run.repoID }
        guard !sameRepo.contains(where: { $0.kind == .mergePR }) else { return false }

        if run.kind == .analyzeRepo {
            let analysesInFlight = inFlight.values.count { $0.kind == .analyzeRepo }
            return analysesInFlight < maxConcurrentAnalyses
        }

        let writersInFlight = inFlight.values.count { $0.kind != .analyzeRepo }
        guard writersInFlight < maxConcurrent else { return false }

        switch run.kind {
        case .mergePR:
            // Waits for an analysis too, at no extra cost: it is in sameRepo.
            return sameRepo.isEmpty
        case .createIssue:
            return !sameRepo.contains { $0.kind == .createIssue }
        case .implementIssue:
            return true
        case .analyzeRepo:
            return true
        }
    }
```

- [x] **Step 4: Take the sentinel baseline in `start(_:)`**

In `RunScheduler.start(_:)`, immediately before `let claudeRun: ClaudeRun`:

```swift
        if updated.isAnalysis {
            // The prompt forbids modifying the repository and no CLI flag can
            // enforce it, so record the tree now and compare after. Do not
            // trust the instruction; check the outcome.
            treeBaselines[run.id] = await git.porcelainStatus(cwd: repo.path)
        }
```

- [x] **Step 5: Split `finish` in two**

Replace the body of `finish(run:outcome:)` from the `var verified` block onwards:

```swift
    private func finish(run: SkillRun, outcome: ClaudeRunOutcome?) async {
        live[run.id] = nil
        inFlight[run.id] = nil

        var updated = (try? await store.run(id: run.id)) ?? run
        updated.endedAt = Date()
        updated.exitCode = outcome?.exitCode
        updated.resultText = outcome?.result?.text ?? outcome?.stderr
        updated.totalCostUSD = outcome?.result?.totalCostUSD
        updated.numTurns = outcome?.result?.numTurns
        updated.permissionDenials = outcome?.result?.permissionDenials.map(\.toolName) ?? []
        updated.state = Self.state(for: outcome)

        // One split, in one place: a card run is verified against gh and writes
        // back to its card; an analysis run is harvested and writes proposals.
        // Letting `finish` acquire two personalities is how this method would
        // become unreadable.
        //
        // if/else rather than a ternary: `inout` arguments are not allowed in
        // one.
        var verified: VerifiedOutcome?
        if updated.isAnalysis {
            await completeAnalysisRun(&updated)
        } else {
            verified = await completeCardRun(&updated)
        }

        try? await store.saveRun(updated)
        continuation.yield(.runFinished(
            runID: run.id, cardID: updated.cardID, state: updated.state, outcome: verified
        ))
        await pump()
    }

    /// Verify against `gh`, then write what it said onto the card.
    private func completeCardRun(_ run: inout SkillRun) async -> VerifiedOutcome? {
        guard let cardID = run.cardID,
              let card = try? await store.card(id: cardID),
              let repo = try? await store.repo(id: run.repoID)
        else { return nil }

        // Verify even a cancelled run: implement-issue may well have opened the
        // pull request before it was stopped, and both skills are resume-safe.
        let verified = await verifier.verify(run: run, card: card, repo: repo)
        run.verifiedOutcome = verified
        await apply(verified, to: card, run: run)
        return verified
    }

    /// Harvest the artifact, then answer the sentinel's question.
    private func completeAnalysisRun(_ run: inout SkillRun) async {
        let baseline = treeBaselines.removeValue(forKey: run.id)

        guard let analysisID = run.analysisID,
              let analysis = try? await store.analysis(id: analysisID),
              let repo = try? await store.repo(id: run.repoID)
        else {
            run.analysisReport = AnalysisRunReport(
                harvestSource: .none,
                dropped: ["The analysis this run belonged to could not be found."]
            )
            return
        }

        var report = await harvester.harvest(
            run: run,
            analysis: analysis,
            repo: repo,
            artifactURL: StoreLocation.analysisArtifactURL(analysisID: analysisID, runID: run.id)
        )

        if let baseline {
            let after = await git.porcelainStatus(cwd: repo.path)
            if after != baseline {
                report.workingTreeChanged = true
                report.workingTreeDiff = after
            }
        }

        run.analysisReport = report
    }
```

`apply(_:to:run:)` keeps its existing body unchanged. Note that `finish` now
saves the run exactly once, at the end — the intermediate save the old code did
before calling `apply` is gone, which is why `completeCardRun` only mutates its
`inout` copy.

- [x] **Step 6: Add `porcelainStatus` to `GitClient`**

In `ElliotKit/Sources/ElliotProcess/GHClient.swift`, replace `isClean(cwd:)`:

```swift
    /// The working tree's changes, exactly as `git status --porcelain` prints
    /// them. Compared before and after an analysis: Elliot cannot stop a run
    /// writing to your repository, so it notices instead.
    public func porcelainStatus(cwd: String) async -> String {
        (try? await run(["status", "--porcelain"], cwd: cwd)) ?? ""
    }

    public func isClean(cwd: String) async -> Bool {
        guard let status = try? await run(["status", "--porcelain"], cwd: cwd) else { return false }
        return status.isEmpty
    }
```

- [x] **Step 7: Teach the reconciler about analysis runs**

In `Reconciler.sweep()`, replace the orphan branch's verification block:

```swift
                if run.isAnalysis {
                    // The artifact may well have been written before the app
                    // died, but the sentinel baseline died with it — say so
                    // rather than claim the tree was clean.
                    orphan.analysisReport = AnalysisRunReport(
                        harvestSource: .none,
                        dropped: ["Elliot stopped before this analysis was harvested."]
                    )
                } else if let cardID = run.cardID,
                          let card = try? await store.card(id: cardID),
                          let repo = try? await store.repo(id: run.repoID) {
                    let outcome = await verifier.verify(run: orphan, card: card, repo: repo)
                    orphan.verifiedOutcome = outcome
                    if await apply(outcome, to: card) { summary.cardsCorrected += 1 }
                }
```

- [x] **Step 8: Run the tests**

Run: `cd ElliotKit && swift test`
Expected: PASS, including the existing `EndToEndTests` — the card path is behaviourally unchanged.

If `inFlight.values.count { … }` does not compile, use `inFlight.values.filter { … }.count`.

- [x] **Step 9: Commit**

```bash
git add ElliotKit/Sources/ElliotEngine ElliotKit/Sources/ElliotProcess/GHClient.swift \
        ElliotKit/Tests/ElliotEngineTests/AnalysisSchedulingTests.swift
git commit -m "feat(engine): admit analyses on their own lane, and watch the tree

An analysis reads the working tree, so it must not overlap a merge in the
same repo — it would see a moving target and the sentinel would fire on
someone else's work. The reverse needs no rule: merge-pr already requires
sameRepo.isEmpty, so it waits for an analysis for free.

Analyses get their own cap because the global cap of 2 exists to keep two
builds out of one .build/, and an analysis builds nothing. Ticking three
angles must not starve a queued implement-issue.

The sentinel: no CLI flag says 'Write, but only under this path', so the
prompt forbids touching the repo and Elliot compares git status before
and after. Do not trust the instruction; check the outcome."
```

---

### Task 9: `AnalysisService` — start, accept, reject

**Files:**
- Create: `ElliotKit/Sources/ElliotEngine/AnalysisService.swift`
- Test: `ElliotKit/Tests/ElliotEngineTests/AnalysisServiceTests.swift`

**Interfaces:**
- Consumes: `BoardStore` analysis methods (Task 6), `AnalysisPromptBuilder` (Task 3), `BoardService.createCard(repoID:title:body:story:column:)`, `RunLaunching`, `GHClient.issues(repo:limit:)`, `StoreLocation.analysisArtifactURL(analysisID:runID:)`.
- Produces: `AnalysisService(store:launcher:board:gh:)`, `.start(repoID:angles:extraInstructions:maxStoriesPerAngle:origin:) async throws -> AnalysisService.Started`, `.accept(proposalIDs:) async throws -> [Card]`, `.reject(proposalIDs:) async throws`, `.updateProposal(_:) async throws`, `AnalysisError`.

**Why the transaction shape matches `commitMove`:** the `analysis` row and its queued runs are written together, and the ids reach the scheduler only afterwards. A crash in between leaves queued runs the launch sweep picks up, not an analysis with nothing behind it.

- [x] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotEngineTests/AnalysisServiceTests.swift`:

```swift
import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine

/// Records what would have been launched, without spawning anything.
private actor LaunchSpy: RunLaunching {
    private(set) var launched: [UUID] = []
    func launch(runID: UUID) async { launched.append(runID) }
    func cancel(runID: UUID) async {}
    func ids() -> [UUID] { launched }
}

@Suite("Analysis service")
struct AnalysisServiceTests {

    private struct Fixture {
        var store: BoardStore
        var service: AnalysisService
        var board: BoardService
        var spy: LaunchSpy
        var repo: Repo
    }

    private func makeFixture(enabled: Bool = true) async throws -> Fixture {
        let store = try BoardStore.inMemory()
        let config = ToolConfig(
            claudePath: "/usr/bin/false", ghPath: "/usr/bin/false",
            gitPath: "/usr/bin/false", environment: [:]
        )
        let spy = LaunchSpy()
        let board = BoardService(store: store, launcher: spy)
        let service = AnalysisService(
            store: store, launcher: spy, board: board, gh: GHClient(config: config)
        )
        var repo = Repo(path: "/tmp/r", nameWithOwner: "phmatray/Elliot", displayName: "Elliot")
        repo.isEnabled = enabled
        try await store.saveRepo(repo)
        return Fixture(store: store, service: service, board: board, spy: spy, repo: repo)
    }

    @Test("Starting an analysis queues one run per angle, each with its own prompt")
    func oneRunPerAngle() async throws {
        let fixture = try await makeFixture()
        let started = try await fixture.service.start(
            repoID: fixture.repo.id, angles: [.bugs, .quickWins, .tests],
            extraInstructions: "focus on ElliotProcess", maxStoriesPerAngle: 5, origin: .manual
        )

        #expect(started.runs.count == 3)
        #expect(Set(started.runs.compactMap(\.analysisAngle)) == [.bugs, .quickWins, .tests])
        #expect(started.runs.allSatisfy { $0.kind == .analyzeRepo })
        #expect(started.runs.allSatisfy { $0.cardID == nil })
        #expect(started.runs.allSatisfy { $0.analysisID == started.analysis.id })
        #expect(started.runs.allSatisfy { $0.state == .queued })
        #expect(await fixture.spy.ids().count == 3)

        // Each prompt announces its own artifact, and only its own.
        for run in started.runs {
            let path = try #require(AnalysisPromptBuilder.outputPath(in: run.prompt))
            #expect(path.hasSuffix("/\(run.id.uuidString)/stories.json"))
            #expect(run.prompt.contains("focus on ElliotProcess"))
            #expect(run.prompt.contains("phmatray/Elliot"))
        }
        // Three distinct artifacts, so two angles cannot overwrite each other.
        let paths = started.runs.compactMap { AnalysisPromptBuilder.outputPath(in: $0.prompt) }
        #expect(Set(paths).count == 3)
    }

    @Test("The prompt lists what is already on the board")
    func promptCarriesExistingTitles() async throws {
        let fixture = try await makeFixture()
        _ = try await fixture.board.createCard(
            repoID: fixture.repo.id, title: "Cache the login shell environment"
        )
        let started = try await fixture.service.start(
            repoID: fixture.repo.id, angles: [.bugs], origin: .manual
        )
        #expect(started.runs[0].prompt.contains("Cache the login shell environment"))
        // gh is unreachable here, so the prompt admits the check was partial.
        #expect(started.runs[0].prompt.contains("could not be reached"))
    }

    @Test("A second run of an angle already in flight is refused, not queued")
    func angleDedupe() async throws {
        let fixture = try await makeFixture()
        _ = try await fixture.service.start(
            repoID: fixture.repo.id, angles: [.bugs], origin: .manual
        )
        await #expect(throws: AnalysisError.self) {
            try await fixture.service.start(
                repoID: fixture.repo.id, angles: [.bugs, .tests], origin: .mcp(client: "x")
            )
        }
    }

    @Test("A disabled repository is refused, and no angles at all is refused")
    func refusals() async throws {
        let disabled = try await makeFixture(enabled: false)
        await #expect(throws: AnalysisError.self) {
            try await disabled.service.start(repoID: disabled.repo.id, angles: [.bugs], origin: .manual)
        }
        let fixture = try await makeFixture()
        await #expect(throws: AnalysisError.self) {
            try await fixture.service.start(repoID: fixture.repo.id, angles: [], origin: .manual)
        }
        await #expect(throws: AnalysisError.self) {
            try await fixture.service.start(repoID: UUID(), angles: [.bugs], origin: .manual)
        }
    }

    @Test("Accepting a proposal lands a Backlog card and runs nothing")
    func acceptCreatesCards() async throws {
        let fixture = try await makeFixture()
        let started = try await fixture.service.start(
            repoID: fixture.repo.id, angles: [.quickWins], origin: .manual
        )
        let proposal = StoryProposal(
            analysisID: started.analysis.id, runID: started.runs[0].id, repoID: fixture.repo.id,
            angle: .quickWins, title: "Add --json to preflight",
            story: UserStory(
                role: "developer", want: "preflight as JSON",
                benefit: "I can gate CI on it", acceptanceCriteria: ["one object per check"]
            ),
            createdAt: Date()
        )
        try await fixture.store.saveProposals([proposal])

        let launchedBefore = await fixture.spy.ids().count
        let cards = try await fixture.service.accept(proposalIDs: [proposal.id])

        #expect(cards.count == 1)
        #expect(cards[0].column == .backlog)
        #expect(cards[0].title == "Add --json to preflight")
        #expect(cards[0].story?.isComplete == true)
        // A card in Backlog fires nothing. Only backlog → todo does.
        #expect(await fixture.spy.ids().count == launchedBefore)

        let back = try #require(try await fixture.store.proposal(id: proposal.id))
        #expect(back.status == .accepted)
        #expect(back.acceptedCardID == cards[0].id)
    }

    @Test("Accepting the same proposal twice creates one card")
    func acceptIsIdempotent() async throws {
        let fixture = try await makeFixture()
        let started = try await fixture.service.start(
            repoID: fixture.repo.id, angles: [.bugs], origin: .manual
        )
        let proposal = StoryProposal(
            analysisID: started.analysis.id, runID: started.runs[0].id, repoID: fixture.repo.id,
            angle: .bugs, title: "Once",
            story: UserStory(role: "dev", want: "w", benefit: "b"), createdAt: Date()
        )
        try await fixture.store.saveProposals([proposal])

        _ = try await fixture.service.accept(proposalIDs: [proposal.id])
        let second = try await fixture.service.accept(proposalIDs: [proposal.id])
        #expect(second.isEmpty)
        #expect(try await fixture.store.cards(repoID: fixture.repo.id).count == 1)
    }

    @Test("Rejecting marks without deleting, so the analysis stays readable")
    func rejectMarks() async throws {
        let fixture = try await makeFixture()
        let started = try await fixture.service.start(
            repoID: fixture.repo.id, angles: [.bugs], origin: .manual
        )
        let proposal = StoryProposal(
            analysisID: started.analysis.id, runID: started.runs[0].id, repoID: fixture.repo.id,
            angle: .bugs, title: "No thanks",
            story: UserStory(role: "dev", want: "w", benefit: "b"), createdAt: Date()
        )
        try await fixture.store.saveProposals([proposal])

        try await fixture.service.reject(proposalIDs: [proposal.id])
        #expect(try await fixture.store.proposal(id: proposal.id)?.status == .rejected)
        #expect(try await fixture.store.proposals(analysisID: started.analysis.id).count == 1)
    }

    @Test("An edited proposal is what becomes the card")
    func editsWinOverTheModel() async throws {
        let fixture = try await makeFixture()
        let started = try await fixture.service.start(
            repoID: fixture.repo.id, angles: [.bugs], origin: .manual
        )
        var proposal = StoryProposal(
            analysisID: started.analysis.id, runID: started.runs[0].id, repoID: fixture.repo.id,
            angle: .bugs, title: "Model's title",
            story: UserStory(role: "dev", want: "vague", benefit: "b"), createdAt: Date()
        )
        try await fixture.store.saveProposals([proposal])

        proposal.title = "My title"
        proposal.story.want = "something precise"
        try await fixture.service.updateProposal(proposal)

        let cards = try await fixture.service.accept(proposalIDs: [proposal.id])
        #expect(cards[0].title == "My title")
        #expect(cards[0].story?.want == "something precise")
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter AnalysisServiceTests`
Expected: FAIL — `cannot find 'AnalysisService' in scope`.

- [x] **Step 3: Write `AnalysisService.swift`**

```swift
import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation

public enum AnalysisError: Error, LocalizedError, Equatable {
    case repoNotFound(UUID)
    case repoDisabled(String)
    case noAngles
    case angleAlreadyRunning(AnalysisAngle)
    case analysisNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .repoNotFound(let id): "No repository with id \(id)."
        case .repoDisabled(let name): "\(name) is disabled in Elliot."
        case .noAngles: "Pick at least one angle to read the repository through."
        case .angleAlreadyRunning(let angle): "A \(angle.title) analysis is already running on this repository."
        case .analysisNotFound(let id): "No analysis with id \(id)."
        }
    }
}

/// Starting analyses, and turning their proposals into cards.
///
/// Acceptance goes through `BoardService.createCard` — the same method the New
/// Card sheet and `board_create_card` use. There is deliberately no second way
/// to make a card, just as there is no second way to move one.
public actor AnalysisService {
    private let store: BoardStore
    private let launcher: any RunLaunching
    private let board: BoardService
    private let gh: GHClient

    public init(store: BoardStore, launcher: any RunLaunching, board: BoardService, gh: GHClient) {
        self.store = store
        self.launcher = launcher
        self.board = board
        self.gh = gh
    }

    public struct Started: Sendable {
        public var analysis: Analysis
        public var runs: [SkillRun]
    }

    // MARK: - Starting

    public func start(
        repoID: UUID,
        angles: [AnalysisAngle],
        extraInstructions: String = "",
        maxStoriesPerAngle: Int = 8,
        origin: AnalysisOrigin
    ) async throws -> Started {
        guard let repo = try await store.repo(id: repoID) else {
            throw AnalysisError.repoNotFound(repoID)
        }
        guard repo.isEnabled else { throw AnalysisError.repoDisabled(repo.displayName) }

        // Ordered-unique: ticking an angle twice in the UI is a slip, not a
        // request for two runs.
        var wanted: [AnalysisAngle] = []
        for angle in angles where !wanted.contains(angle) { wanted.append(angle) }
        guard !wanted.isEmpty else { throw AnalysisError.noAngles }

        // Dedupe key `(repoID, angle)`, refused rather than queued — the same
        // rule as a second `implement-issue 47`. It is also what contains the
        // one loop worth worrying about: an analysis run inherits the user's
        // MCP config, so its agent can see `elliot` and call board_analyze_repo.
        let inFlight = Set(
            (try await store.activeAnalysisRuns(repoID: repoID)).compactMap(\.analysisAngle)
        )
        if let clash = wanted.first(where: inFlight.contains) {
            throw AnalysisError.angleAlreadyRunning(clash)
        }

        let (titles, githubReachable) = await existingTitles(repo: repo)

        let now = Date()
        let analysis = Analysis(
            repoID: repoID, angles: wanted, extraInstructions: extraInstructions,
            maxStoriesPerAngle: maxStoriesPerAngle, origin: origin, createdAt: now
        )

        var runs: [SkillRun] = []
        for angle in wanted {
            let runID = UUID()
            let artifact = StoreLocation.analysisArtifactURL(analysisID: analysis.id, runID: runID)
            // Created up front so the agent has somewhere to write, and so
            // `--add-dir` points at a directory that exists.
            try? FileManager.default.createDirectory(
                at: artifact.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            runs.append(SkillRun(
                id: runID,
                cardID: nil,
                repoID: repoID,
                analysisID: analysis.id,
                analysisAngle: angle,
                kind: .analyzeRepo,
                prompt: AnalysisPromptBuilder.prompt(
                    angle: angle,
                    repoNameWithOwner: repo.nameWithOwner,
                    outputPath: artifact.path,
                    existingTitles: titles,
                    maxStories: maxStoriesPerAngle,
                    extraInstructions: extraInstructions,
                    githubTitlesAvailable: githubReachable
                ),
                cwd: repo.path,
                logPath: StoreLocation.runLogURL(runID: runID).path,
                stderrPath: StoreLocation.runStderrURL(runID: runID).path,
                createdAt: now
            ))
        }

        // The analysis and its runs land together; the scheduler is handed the
        // ids only after. A crash in between leaves queued runs for the launch
        // sweep rather than an analysis with nothing behind it — the same shape
        // as `commitMove`.
        try await store.saveAnalysis(analysis)
        for run in runs { try await store.saveRun(run) }
        for run in runs { await launcher.launch(runID: run.id) }

        return Started(analysis: analysis, runs: runs)
    }

    /// Board titles and open issue titles, newest first.
    ///
    /// The second element says whether GitHub answered: a partial duplicate
    /// check should be admitted in the prompt, not passed off as a complete one.
    private func existingTitles(repo: Repo) async -> ([String], Bool) {
        var dated: [(Date, String)] = []
        for card in (try? await store.cards(repoID: repo.id)) ?? [] {
            let title = card.displayTitle
            if !title.isEmpty { dated.append((card.createdAt, title)) }
        }

        var reachable = false
        if let issues = try? await gh.issues(repo: repo.nameWithOwner, limit: 100) {
            reachable = true
            for issue in issues where issue.isOpen {
                dated.append((issue.createdAt ?? .distantPast, issue.title))
            }
        }

        let titles = dated
            .sorted { $0.0 > $1.0 }
            .map(\.1)
            .prefix(AnalysisPromptBuilder.maxExistingTitles)
        return (Array(titles), reachable)
    }

    // MARK: - Reading

    public func analyses(repoID: UUID? = nil, limit: Int = 50) async throws -> [Analysis] {
        try await store.analyses(repoID: repoID, limit: limit)
    }

    public func proposals(
        analysisID: UUID? = nil,
        repoID: UUID? = nil,
        status: ProposalStatus? = nil,
        limit: Int = 500
    ) async throws -> [StoryProposal] {
        try await store.proposals(
            analysisID: analysisID, repoID: repoID, status: status, limit: limit
        )
    }

    // MARK: - Deciding

    /// The edited proposal is what will become the card. That is the point of
    /// letting them be edited: the corrected story reaches the board, not the
    /// model's first draft.
    public func updateProposal(_ proposal: StoryProposal) async throws {
        try await store.saveProposal(proposal)
    }

    @discardableResult
    public func accept(proposalIDs: [UUID]) async throws -> [Card] {
        var created: [Card] = []
        for id in proposalIDs {
            guard var proposal = try await store.proposal(id: id) else { continue }
            // Already decided: accepting twice must not make two cards.
            guard proposal.status == .proposed else { continue }

            let card = try await board.createCard(
                repoID: proposal.repoID,
                title: proposal.title,
                body: proposal.rationale,
                story: proposal.story,
                column: .backlog
            )
            proposal.status = .accepted
            proposal.acceptedCardID = card.id
            try await store.saveProposal(proposal)
            created.append(card)
        }
        return created
    }

    public func reject(proposalIDs: [UUID]) async throws {
        for id in proposalIDs {
            guard var proposal = try await store.proposal(id: id), proposal.status == .proposed
            else { continue }
            // Marked, not deleted: an analysis you have been through should
            // still read as what it found, including what you turned down.
            proposal.status = .rejected
            try await store.saveProposal(proposal)
        }
    }
}
```

- [x] **Step 4: Run test to verify it passes**

Run: `cd ElliotKit && swift test --filter AnalysisServiceTests`
Expected: PASS.

`start` writes into `StoreLocation`'s real home. That is intentional — it is a directory create, not a database write — but if the sandbox forbids it, the `try?` swallows it and the test still passes.

- [x] **Step 5: Run the whole suite and commit**

```bash
cd ElliotKit && swift test && cd ..
git add ElliotKit/Sources/ElliotEngine/AnalysisService.swift \
        ElliotKit/Tests/ElliotEngineTests/AnalysisServiceTests.swift
git commit -m "feat(engine): start analyses, and turn proposals into cards

The analysis row and its queued runs land together and the scheduler gets
the ids only after — same shape as commitMove, so a crash in between
leaves queued runs for the launch sweep rather than an analysis with
nothing behind it.

Acceptance goes through BoardService.createCard, the method the New Card
sheet and board_create_card already use. There is no second way to make a
card, just as there is no second way to move one.

(repoID, angle) is refused rather than queued. That is also what contains
the one loop worth worrying about: an analysis run inherits the user's MCP
config, so its agent can see elliot and call board_analyze_repo."
```

---

### Task 10: The fake `claude` writes an artifact, and the whole path is tested

**Files:**
- Modify: `Scripts/fake-claude.sh`
- Create: `Fixtures/analysis/e2e-bugs.json`
- Create: `Fixtures/stream-json/analyze-success.ndjson`
- Test: `ElliotKit/Tests/ElliotEngineTests/AnalysisEndToEndTests.swift`
- Modify: `ElliotKit/Tests/ElliotEngineTests/EndToEndTests.swift:35-41,85-86` (see Step 4b)

**Interfaces:**
- Consumes: everything from Tasks 1–9.
- Produces: `FAKE_CLAUDE_STORIES` and `FAKE_CLAUDE_TOUCH` in the fake tool.

**What this proves:** one test crosses every new seam — prompt → spawn → artifact → harvest → evidence → duplicate hint → accept → Backlog card → drag to To Do → `create-issue` fires — and joins them to the seams that already existed. Without spending a token or touching GitHub.

- [x] **Step 1: Extend `Scripts/fake-claude.sh`**

Add to the header comment block:

```bash
#   FAKE_CLAUDE_STORIES    path to a JSON file to drop at the analysis output
#                          path the prompt announces (ELLIOT_OUTPUT=…)
#   FAKE_CLAUDE_TOUCH      path, relative to cwd, to write to — used to prove
#                          the git sentinel notices a run that edits the repo
```

Insert after the `FAKE_CLAUDE_STDERR` block and before the `case "${FAKE_CLAUDE_MODE:-replay}"` switch:

```bash
# Elliot announces the analysis artifact path in the prompt itself, with a
# marker chosen so it can be found in shell as easily as in Swift. Finding it
# here is what makes the whole analysis path testable without a real agent.
if [ -n "${FAKE_CLAUDE_STORIES:-}" ]; then
  prompt=""
  prev=""
  for arg in "$@"; do
    if [ "$prev" = "-p" ]; then prompt="$arg"; fi
    prev="$arg"
  done
  out="$(printf '%s\n' "$prompt" \
    | sed -n 's/.*ELLIOT_OUTPUT=\([^[:space:]]*\).*/\1/p' | head -1)"
  if [ -n "$out" ]; then
    mkdir -p "$(dirname "$out")"
    cp "$FAKE_CLAUDE_STORIES" "$out"
  fi
fi

if [ -n "${FAKE_CLAUDE_TOUCH:-}" ]; then
  printf 'touched by fake-claude\n' >"$FAKE_CLAUDE_TOUCH"
fi
```

Note the pipeline takes its stdin from `printf`, not from the script, so it cannot repeat the bug where a helper process inside the replay loop ate the unread fixture lines.

- [x] **Step 2: Verify the fake by hand**

```bash
mkdir -p /tmp/elliot-fake && cat > /tmp/elliot-fake/in.json <<'JSON'
[{"title":"T","role":"dev","want":"w","benefit":"b","evidence":["A.swift:1"]}]
JSON
FAKE_CLAUDE_STORIES=/tmp/elliot-fake/in.json \
  ./Scripts/fake-claude.sh -p 'blah ELLIOT_OUTPUT=/tmp/elliot-fake/out/stories.json blah'
cat /tmp/elliot-fake/out/stories.json
```

Expected: the JSON is printed. If it is not, the `sed` did not match — check the marker is present and followed by a non-space path.

- [x] **Step 3: Write the fixtures**

Create `Fixtures/analysis/e2e-bugs.json`:

```json
[
  {
    "title": "The idle watchdog outlives a cancelled run",
    "role": "developer",
    "want": "the idle task cancelled on every exit path",
    "benefit": "a cancelled run stops waking the machine every 30 seconds",
    "acceptance_criteria": [
      "cancelling a run cancels its idle task",
      "a test asserts no timer survives the run"
    ],
    "rationale": "The idle task is only cancelled after waitForExit returns.",
    "evidence": ["Sources/ElliotProcess/ClaudeRunner.swift:159"],
    "effort": "small"
  },
  {
    "title": "Cache the login shell environment",
    "role": "user",
    "want": "Elliot to start without waiting on a login shell",
    "benefit": "the board is usable immediately after launch",
    "acceptance_criteria": ["the capture is reused until ~/.zshrc changes"],
    "rationale": "Every launch pays for a full zsh -lic.",
    "evidence": ["Sources/ElliotProcess/LoginShellEnvironment.swift"],
    "effort": "medium"
  },
  {
    "title": "Unusable on purpose",
    "role": "developer",
    "want": "to prove a broken story is dropped with its reason",
    "evidence": ["Sources/ElliotModel/Card.swift:1"]
  }
]
```

Create `Fixtures/stream-json/analyze-success.ndjson` — copy the shape of `create-issue-success.ndjson`, four lines: a `system/init`, an `assistant` text, an `assistant` `tool_use` for Write, and a terminal `result`:

```
{"type":"system","subtype":"init","session_id":"00000000-0000-0000-0000-000000000000","cwd":"/tmp/r","model":"claude-opus-5","permissionMode":"bypassPermissions","tools":["Read","Grep","Glob","Write"],"slash_commands":[],"mcp_servers":[]}
{"type":"assistant","message":{"content":[{"type":"text","text":"Reading the process layer for defects."}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_1","name":"Write","input":{"file_path":"stories.json"}}]}}
{"type":"result","subtype":"success","is_error":false,"result":"Wrote 3 candidate stories.","num_turns":5,"duration_ms":41000,"total_cost_usd":0.0912,"session_id":"00000000-0000-0000-0000-000000000000","permission_denials":[]}
```

- [x] **Step 4: Write the end-to-end test**

Create `ElliotKit/Tests/ElliotEngineTests/AnalysisEndToEndTests.swift`:

```swift
import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation
import Testing

@testable import ElliotEngine

/// Duplicated rather than shared with `EndToEndTests`: a private enum in one
/// test file is not visible from another, and one small repetition beats a
/// shared helper target for two constants.
private enum TestPaths {
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let fakeClaude = repoRoot.appendingPathComponent("Scripts/fake-claude.sh").path

    static func streamFixture(_ name: String) -> String {
        repoRoot.appendingPathComponent("Fixtures/stream-json/\(name)").path
    }

    static func analysisFixture(_ name: String) -> String {
        repoRoot.appendingPathComponent("Fixtures/analysis/\(name)").path
    }
}

/// One `ELLIOT_HOME` for the whole test process, set once and never removed.
///
/// `StoreLocation` reads the variable on every access and it is process-global,
/// so a per-test home that gets deleted at the end of one test pulls the ground
/// out from under any suite still writing run logs. Both end-to-end suites are
/// nested under one `.serialized` parent for the same reason.
///
/// This also fixes something that was already true: without it, the existing
/// end-to-end suite writes its run logs into the real
/// `~/Library/Application Support/Elliot/runs`.
enum TestHome {
    /// `nonisolated(unsafe)` because it is written exactly once, before any
    /// test body runs, by the `static let` initialiser itself.
    static let root: URL = {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elliot-tests-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        setenv("ELLIOT_HOME", url.path, 1)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// A directory of one test's own, inside the shared home. Safe to delete:
    /// nothing else writes here.
    static func scratch(_ label: String) -> URL {
        _ = root
        return root.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    }
}

/// Both end-to-end suites nested under one serialized parent. They share a
/// process-global `ELLIOT_HOME`, so they must not run at the same time.
@Suite("End to end", .serialized)
struct EndToEndSuites {}

extension EndToEndSuites {

@Suite("Analysis end to end", .serialized)
struct AnalysisEndToEndTests {

    private struct Stack {
        var store: BoardStore
        var board: BoardService
        var scheduler: RunScheduler
        var analysisService: AnalysisService
        var repo: Repo
        var home: URL

        /// Removes this test's own directory only. The shared `ELLIOT_HOME`
        /// above it stays: another suite may still be writing into it.
        func cleanUp() { try? FileManager.default.removeItem(at: home) }

        func awaitRuns(analysisID: UUID, timeout: Duration = .seconds(30)) async throws -> [SkillRun] {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while ContinuousClock.now < deadline {
                let runs = try await store.runs(analysisID: analysisID)
                if !runs.isEmpty, runs.allSatisfy({ $0.state.isTerminal }) { return runs }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw StackError.timedOut
        }

        enum StackError: Error { case timedOut }
    }

    /// The prompt, the fake tool and the harvester must agree on one artifact
    /// path, and that agreement is what is under test — so `StoreLocation` has
    /// to resolve somewhere writable. `TestHome` provides that once for the
    /// process; this test only owns a scratch directory inside it.
    ///
    /// The database is explicitly per-test: `StoreLocation.databaseURL` is
    /// shared now, and two suites must not open the same file.
    private func makeStack(extraEnv: [String: String] = [:]) async throws -> Stack {
        let home = TestHome.scratch("analysis-e2e")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try StoreLocation.ensureDirectories()

        let repoRoot = home.appendingPathComponent("repo", isDirectory: true)
        let sources = repoRoot.appendingPathComponent("Sources/ElliotProcess", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "// real".write(
            to: sources.appendingPathComponent("ClaudeRunner.swift"), atomically: true, encoding: .utf8
        )

        let store = try BoardStore.open(at: home.appendingPathComponent("elliot.sqlite"))
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        environment["FAKE_CLAUDE_FIXTURE"] = TestPaths.streamFixture("analyze-success.ndjson")
        environment["FAKE_CLAUDE_STORIES"] = TestPaths.analysisFixture("e2e-bugs.json")
        environment.merge(extraEnv) { _, new in new }

        let config = ToolConfig(
            claudePath: TestPaths.fakeClaude,
            ghPath: "/usr/bin/false",
            gitPath: "/usr/bin/false",
            environment: environment
        )
        let scheduler = RunScheduler(
            store: store, toolConfig: config, verifier: Verifier(gh: .init(config: config))
        )
        let board = BoardService(store: store, launcher: scheduler)
        await scheduler.setSystemMover(board)
        let analysisService = AnalysisService(
            store: store, launcher: scheduler, board: board, gh: GHClient(config: config)
        )

        let repo = Repo(
            path: repoRoot.path, nameWithOwner: "phmatray/Elliot", displayName: "Elliot"
        )
        try await store.saveRepo(repo)

        return Stack(
            store: store, board: board, scheduler: scheduler,
            analysisService: analysisService, repo: repo, home: home
        )
    }

    @Test("An analysis produces proposals, and accepting one puts a real card in Backlog")
    func theWholePath() async throws {
        let stack = try await makeStack()
        defer { stack.cleanUp() }

        // A card already on the board, so the duplicate hint has something to
        // collide with.
        _ = try await stack.board.createCard(
            repoID: stack.repo.id, title: "Cache the login shell environment"
        )

        let started = try await stack.analysisService.start(
            repoID: stack.repo.id, angles: [.bugs, .quickWins],
            maxStoriesPerAngle: 8, origin: .manual
        )
        #expect(started.runs.count == 2)

        let runs = try await stack.awaitRuns(analysisID: started.analysis.id)
        #expect(runs.count == 2)
        #expect(runs.allSatisfy { $0.state == .succeeded })
        #expect(runs.allSatisfy { $0.exitCode == 0 })

        // Both runs harvested from the artifact, not from prose.
        for run in runs {
            let report = try #require(run.analysisReport)
            #expect(report.harvestSource == .artifact)
            #expect(report.kept == 2)
            // The third story in the fixture is unusable, and says why.
            #expect(report.dropped.contains { $0.contains("benefit") })
            #expect(!report.workingTreeChanged)
        }

        // Two angles × two usable stories.
        let proposals = try await stack.store.proposals(analysisID: started.analysis.id)
        #expect(proposals.count == 4)

        let watchdog = try #require(proposals.first { $0.title.contains("idle watchdog") })
        #expect(watchdog.effort == .small)
        #expect(watchdog.story.acceptanceCriteria.count == 2)
        // The cited file exists in this fixture repo; the other one does not.
        #expect(watchdog.evidence.first?.exists == true)
        #expect(watchdog.isGrounded)

        let cached = try #require(proposals.first { $0.title.contains("Cache the login shell") })
        #expect(cached.evidence.first?.exists == false)
        guard case .card? = cached.duplicateOf else {
            Issue.record("expected a duplicate hint against the existing card")
            return
        }

        // Accept one. It lands in Backlog and fires nothing.
        let cards = try await stack.analysisService.accept(proposalIDs: [watchdog.id])
        #expect(cards.count == 1)
        let card = cards[0]
        #expect(card.column == .backlog)
        #expect(try await stack.store.runs(cardID: card.id).isEmpty)

        // And it behaves like any other card: dragging it to To Do runs
        // create-issue, through the same funnel and the same rule engine.
        let result = try await stack.board.move(cardID: card.id, to: .todo, origin: .userDrag)
        guard case .moved(let runID?) = result else {
            Issue.record("expected a run, got \(result)")
            return
        }
        let issueRun = try #require(try await stack.store.run(id: runID))
        #expect(issueRun.kind == .createIssue)
        #expect(issueRun.cardID == card.id)
        #expect(issueRun.prompt.hasPrefix("/ai-migration-kit:create-issue"))
        #expect(issueRun.prompt.contains("the idle task cancelled on every exit path"))
    }

    @Test("An analysis that edits the repository is reported, not hidden")
    func theSentinelFires() async throws {
        let stack = try await makeStack(extraEnv: ["FAKE_CLAUDE_TOUCH": "meddled.txt"])
        defer { stack.cleanUp() }

        // A real git binary is needed for the sentinel to say anything.
        let git = "/usr/bin/git"
        guard FileManager.default.isExecutableFile(atPath: git) else { return }
        _ = try? await ProcessRunner.run(
            executable: git, arguments: ["init", "-q"], cwd: stack.repo.path,
            environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(20)
        )

        // Rebuild the stack's scheduler with a working git, keeping everything
        // else identical.
        let config = ToolConfig(
            claudePath: TestPaths.fakeClaude, ghPath: "/usr/bin/false", gitPath: git,
            environment: [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "FAKE_CLAUDE_FIXTURE": TestPaths.streamFixture("analyze-success.ndjson"),
                "FAKE_CLAUDE_STORIES": TestPaths.analysisFixture("e2e-bugs.json"),
                "FAKE_CLAUDE_TOUCH": "meddled.txt",
            ]
        )
        let scheduler = RunScheduler(
            store: stack.store, toolConfig: config, verifier: Verifier(gh: .init(config: config))
        )
        let board = BoardService(store: stack.store, launcher: scheduler)
        await scheduler.setSystemMover(board)
        let service = AnalysisService(
            store: stack.store, launcher: scheduler, board: board, gh: GHClient(config: config)
        )

        let started = try await service.start(
            repoID: stack.repo.id, angles: [.bugs], origin: .manual
        )
        let runs = try await stack.awaitRuns(analysisID: started.analysis.id)
        let report = try #require(runs.first?.analysisReport)

        // Elliot cannot stop a run writing to the repo. It notices.
        #expect(report.workingTreeChanged)
        #expect(report.workingTreeDiff?.contains("meddled.txt") == true)
        // And the proposals are still harvested — the sentinel reports, it does
        // not punish.
        #expect(report.kept == 2)
    }
}

}  // extension EndToEndSuites
```

- [x] **Step 4b: Nest the existing end-to-end suite under the same parent**

In `ElliotKit/Tests/ElliotEngineTests/EndToEndTests.swift`, wrap the existing
suite so the two cannot run at the same time — they share one process-global
`ELLIOT_HOME`:

```swift
extension EndToEndSuites {

@Suite("End to end", .serialized)
struct EndToEndTests {
    …unchanged…
}

}  // extension EndToEndSuites
```

And give it a home that is not the user's real one. Replace the two lines at the
top of `Stack.make`:

```swift
        let home = TestHome.scratch("board-e2e")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("runs"), withIntermediateDirectories: true
        )
        try StoreLocation.ensureDirectories()
```

Its `BoardStore.open(at:)` call already names an explicit path, so nothing else
in that file changes.

- [x] **Step 5: Run the end-to-end suite**

Run: `cd ElliotKit && swift test --filter AnalysisEndToEndTests`
Expected: PASS, both tests.

If `theWholePath` times out, check in order: the artifact exists at `$ELLIOT_HOME/analyses/<analysisID>/<runID>/stories.json` after the run; the prompt's `ELLIOT_OUTPUT=` path matches it; `Scripts/fake-claude.sh` is executable (`chmod +x`).

- [x] **Step 6: Run the whole suite and commit**

```bash
cd ElliotKit && swift test && cd ..
chmod +x Scripts/fake-claude.sh
git add Scripts/fake-claude.sh Fixtures ElliotKit/Tests/ElliotEngineTests/AnalysisEndToEndTests.swift
git commit -m "test: the whole analysis path, without a token or a GitHub call

The fake claude finds the artifact path the same way Elliot does — by
grepping the prompt for ELLIOT_OUTPUT= — which is what makes the marker
worth being an invariant rather than a convention.

One test crosses every new seam and joins them to the old ones: prompt,
spawn, artifact, harvest, evidence resolution, duplicate hint, accept,
Backlog card, drag to To Do, create-issue fires. A second proves the git
sentinel reports a meddling run rather than hiding it — and still keeps
its proposals, because the sentinel reports, it does not punish."
```

---

### Task 11: The wire — IPC requests, DTOs and the handler

**Files:**
- Modify: `ElliotKit/Sources/ElliotIPC/Protocol.swift`
- Modify: `ElliotKit/Sources/ElliotApp/MCPRequestHandler.swift`
- Test: `ElliotKit/Tests/ElliotIPCTests/AnalysisWireTests.swift`

**Interfaces:**
- Consumes: `AnalysisService` (Task 9), `Analysis`, `StoryProposal` (Task 1).
- Produces: `ElliotRequest.analyzeRepo/listProposals/acceptProposals/rejectProposals`, `ElliotPayload.analysisStarted/proposals/proposalsDecided`, `AnalysisDTO`, `AnalysisRunDTO`, `ProposalDTO`, `DecisionDTO`, three new `ElliotErrorCode` cases, `elliotProtocolVersion == 2`.

**Why the version bumps:** a helper embedded in an older app bundle meeting this app must fail loudly on `hello` rather than send a request the app cannot decode. That is what the constant is for.

- [x] **Step 1: Write the failing test**

Create `ElliotKit/Tests/ElliotIPCTests/AnalysisWireTests.swift`:

```swift
import ElliotModel
import Foundation
import Testing

@testable import ElliotIPC

@Suite("Analysis wire format")
struct AnalysisWireTests {

    @Test("The protocol version moved, so an old helper fails loudly")
    func versionBumped() {
        #expect(elliotProtocolVersion == 2)
    }

    @Test("Every new request round-trips through the wire codec", arguments: [
        ElliotRequest.analyzeRepo(
            repo: "phmatray/Elliot", angles: ["bugs", "quickWins"],
            maxStories: 5, instructions: "focus on ElliotProcess"
        ),
        .listProposals(analysisID: UUID(), repo: nil, status: "proposed", limit: 100),
        .listProposals(analysisID: nil, repo: "phmatray/Elliot", status: nil, limit: 20),
        .acceptProposals(ids: [UUID(), UUID()]),
        .rejectProposals(ids: [UUID()]),
    ])
    func requestsRoundTrip(request: ElliotRequest) throws {
        let line = try WireCodec.encodeLine(Envelope(body: request))
        let back = try WireCodec.decode(
            Envelope<ElliotRequest>.self, from: line.dropLast()
        )
        // Re-encoding the decoded value must produce the same bytes: that is
        // the only cheap way to assert an enum with payloads survived intact.
        #expect(try WireCodec.encodeLine(Envelope(id: back.id, body: back.body)) == line)
    }

    @Test("A proposal DTO carries what an agent needs to decide")
    func proposalDTOIsSelfDescribing() throws {
        let proposal = StoryProposal(
            analysisID: UUID(), runID: UUID(), repoID: UUID(), angle: .quickWins,
            title: "Add --json to preflight",
            story: UserStory(
                role: "developer", want: "preflight as JSON",
                benefit: "I can gate CI on it", acceptanceCriteria: ["one object per check"]
            ),
            rationale: "The checks already exist.",
            evidence: [Evidence(path: "Sources/A.swift", line: 3, exists: true)],
            effort: .small,
            duplicateOf: .issue(number: 12, title: "Preflight JSON"),
            createdAt: Date()
        )
        let dto = ProposalDTO(proposal: proposal, repoName: "phmatray/Elliot")
        #expect(dto.angle == "quickWins")
        #expect(dto.effort == "small")
        #expect(dto.status == "proposed")
        #expect(dto.grounded)
        #expect(dto.evidence == ["Sources/A.swift:3"])
        #expect(dto.duplicateHint?.contains("#12") == true)
        #expect(dto.story.narrative.hasPrefix("As a developer"))

        // And it survives the wire.
        let data = try WireCodec.encoder.encode(dto)
        let back = try WireCodec.decoder.decode(ProposalDTO.self, from: data)
        #expect(back == dto)
    }

    @Test("An analysis DTO says what was asked and what is running")
    func analysisDTO() {
        let analysis = Analysis(
            repoID: UUID(), angles: [.bugs, .tests], extraInstructions: "",
            maxStoriesPerAngle: 8, origin: .mcp(client: "claude-code"), createdAt: Date()
        )
        let dto = AnalysisDTO(
            analysis: analysis, repoName: "phmatray/Elliot",
            runs: [AnalysisRunDTO(runID: UUID(), angle: "bugs", state: "queued")]
        )
        #expect(dto.angles == ["bugs", "tests"])
        #expect(dto.runs.count == 1)
        #expect(dto.repo == "phmatray/Elliot")
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter AnalysisWireTests`
Expected: FAIL — `type 'ElliotRequest' has no member 'analyzeRepo'`.

- [x] **Step 3: Extend `Protocol.swift`**

Bump the version, with the reason kept next to it:

```swift
/// Bumped whenever the wire format changes. A helper embedded in an old app
/// bundle meeting a newer app fails loudly on `hello` rather than misbehaving
/// halfway through a move.
///
/// 2 — repository analysis: `analyzeRepo`, `listProposals`, `acceptProposals`,
///     `rejectProposals`.
public let elliotProtocolVersion = 2
```

Add the cases to `ElliotRequest`:

```swift
    /// Angles arrive as strings so an unknown one is a clear error message
    /// rather than a decoding failure that loses the whole request.
    case analyzeRepo(repo: String, angles: [String], maxStories: Int, instructions: String)
    case listProposals(analysisID: UUID?, repo: String?, status: String?, limit: Int)
    case acceptProposals(ids: [UUID])
    case rejectProposals(ids: [UUID])
```

Add the error codes:

```swift
    case analysisNotFound = "analysis_not_found"
    case proposalNotFound = "proposal_not_found"
    case unknownAngle = "unknown_angle"
    case analysisRefused = "analysis_refused"
```

Add the payload cases:

```swift
    case analysisStarted(AnalysisDTO)
    case proposals([ProposalDTO])
    case proposalsDecided(DecisionDTO)
```

And the wire shapes, at the end of the "Wire shapes" section:

```swift
public struct AnalysisRunDTO: Codable, Sendable, Hashable {
    public var runID: UUID
    public var angle: String
    public var state: String

    public init(runID: UUID, angle: String, state: String) {
        self.runID = runID
        self.angle = angle
        self.state = state
    }
}

public struct AnalysisDTO: Codable, Sendable, Hashable {
    public var id: UUID
    public var repo: String
    public var angles: [String]
    public var maxStoriesPerAngle: Int
    public var createdAt: Date
    public var runs: [AnalysisRunDTO]

    public init(analysis: Analysis, repoName: String, runs: [AnalysisRunDTO]) {
        id = analysis.id
        repo = repoName
        angles = analysis.angles.map(\.rawValue)
        maxStoriesPerAngle = analysis.maxStoriesPerAngle
        createdAt = analysis.createdAt
        self.runs = runs
    }
}

public struct ProposalDTO: Codable, Sendable, Hashable {
    public var id: UUID
    public var analysisID: UUID
    public var repo: String
    public var angle: String
    public var title: String
    public var story: CardDTO.StoryDTO
    public var rationale: String
    /// `path:line`, as cited. See `grounded` for whether they were found.
    public var evidence: [String]
    /// Every cited file was found in the repository. A proposal that is not
    /// grounded may still be right — but it was not checkable.
    public var grounded: Bool
    public var effort: String
    public var status: String
    public var duplicateHint: String?
    public var acceptedCardID: UUID?

    public init(proposal: StoryProposal, repoName: String) {
        id = proposal.id
        analysisID = proposal.analysisID
        repo = repoName
        angle = proposal.angle.rawValue
        title = proposal.title
        story = CardDTO.StoryDTO(proposal.story)
        rationale = proposal.rationale
        evidence = proposal.evidence.map(\.display)
        grounded = proposal.isGrounded
        effort = proposal.effort.rawValue
        status = proposal.status.rawValue
        duplicateHint = proposal.duplicateOf?.label
        acceptedCardID = proposal.acceptedCardID
    }
}

public struct DecisionDTO: Codable, Sendable, Hashable {
    public var decided: [UUID]
    public var skipped: [UUID]
    public var cards: [CardDTO]
    /// Plain-language account for the agent to relay.
    public var summary: String

    public init(decided: [UUID], skipped: [UUID], cards: [CardDTO], summary: String) {
        self.decided = decided
        self.skipped = skipped
        self.cards = cards
        self.summary = summary
    }
}
```

- [x] **Step 4: Handle the new requests in `MCPRequestHandler.swift`**

Add `analysisService` to the type:

```swift
    private let store: BoardStore
    private let board: BoardService
    private let analysis: AnalysisService

    public init(store: BoardStore, board: BoardService, analysis: AnalysisService) {
        self.store = store
        self.board = board
        self.analysis = analysis
    }
```

Add the four cases to `handle(_:)`'s switch, and an `AnalysisError` catch clause:

```swift
            case .analyzeRepo(let repo, let angles, let maxStories, let instructions):
                return try await analyze(
                    repo: repo, angles: angles, maxStories: maxStories, instructions: instructions
                )
            case .listProposals(let analysisID, let repo, let status, let limit):
                return try await listProposals(
                    analysisID: analysisID, repo: repo, status: status, limit: limit
                )
            case .acceptProposals(let ids):
                return try await decide(ids: ids, accept: true)
            case .rejectProposals(let ids):
                return try await decide(ids: ids, accept: false)
```

```swift
        } catch let error as AnalysisError {
            switch error {
            case .repoNotFound(let id):
                return .failure(code: .repoNotFound, message: "No repository \(id).", hint: nil)
            case .analysisNotFound(let id):
                return .failure(code: .analysisNotFound, message: "No analysis \(id).", hint: nil)
            case .noAngles, .repoDisabled, .angleAlreadyRunning:
                return .failure(
                    code: .analysisRefused,
                    message: error.localizedDescription,
                    hint: error == .noAngles
                        ? "Pick from: \(AnalysisAngle.allCases.map(\.rawValue).joined(separator: ", "))."
                        : "Poll board_list_runs and try again when it finishes."
                )
            }
        }
```

And the three methods:

```swift
    private func analyze(
        repo: String, angles: [String], maxStories: Int, instructions: String
    ) async throws -> ElliotResponse {
        let repos = try await store.repos()
        guard let match = repos.first(where: { $0.nameWithOwner == repo || $0.path == repo }) else {
            return .failure(
                code: .repoNotFound,
                message: "No registered repository matches \"\(repo)\".",
                hint: "Known: \(repos.map(\.nameWithOwner).joined(separator: ", "))"
            )
        }
        // An unknown angle is worth its own message: a decoding failure would
        // lose the whole request and say nothing useful about why.
        var resolved: [AnalysisAngle] = []
        for raw in angles {
            guard let angle = AnalysisAngle(rawValue: raw) else {
                return .failure(
                    code: .unknownAngle,
                    message: "\"\(raw)\" is not an angle.",
                    hint: "One of: \(AnalysisAngle.allCases.map(\.rawValue).joined(separator: ", "))."
                )
            }
            resolved.append(angle)
        }

        let started = try await analysis.start(
            repoID: match.id,
            angles: resolved,
            extraInstructions: instructions,
            maxStoriesPerAngle: max(1, min(maxStories, 30)),
            origin: .mcp(client: "mcp")
        )
        return .ok(.analysisStarted(AnalysisDTO(
            analysis: started.analysis,
            repoName: match.nameWithOwner,
            runs: started.runs.map {
                AnalysisRunDTO(
                    runID: $0.id,
                    angle: $0.analysisAngle?.rawValue ?? "",
                    state: $0.state.rawValue
                )
            }
        )))
    }

    private func listProposals(
        analysisID: UUID?, repo: String?, status: String?, limit: Int
    ) async throws -> ElliotResponse {
        let repos = try await store.repos()
        var repoID: UUID?
        if let repo {
            guard let match = repos.first(where: { $0.nameWithOwner == repo || $0.path == repo }) else {
                return .failure(
                    code: .repoNotFound,
                    message: "No registered repository matches \"\(repo)\".",
                    hint: "Known: \(repos.map(\.nameWithOwner).joined(separator: ", "))"
                )
            }
            repoID = match.id
        }
        let proposals = try await store.proposals(
            analysisID: analysisID,
            repoID: repoID,
            status: status.flatMap(ProposalStatus.init(rawValue:)),
            limit: limit
        )
        return .ok(.proposals(proposals.map { proposal in
            ProposalDTO(
                proposal: proposal,
                repoName: repos.first { $0.id == proposal.repoID }?.nameWithOwner ?? "?"
            )
        }))
    }

    private func decide(ids: [UUID], accept: Bool) async throws -> ElliotResponse {
        let known = try await withThrowingTaskGroup(of: UUID?.self) { group -> Set<UUID> in
            for id in ids {
                group.addTask { try await self.store.proposal(id: id)?.id }
            }
            var found: Set<UUID> = []
            for try await id in group { if let id { found.insert(id) } }
            return found
        }
        let skipped = ids.filter { !known.contains($0) }

        guard accept else {
            try await analysis.reject(proposalIDs: ids)
            return .ok(.proposalsDecided(DecisionDTO(
                decided: ids.filter(known.contains), skipped: skipped, cards: [],
                summary: "Rejected \(known.count) proposal(s). They stay on the analysis, marked."
            )))
        }

        let cards = try await analysis.accept(proposalIDs: ids)
        let repos = try await store.repos()
        let dtos = cards.map { card in
            CardDTO(card: card, repoName: repos.first { $0.id == card.repoID }?.nameWithOwner ?? "?")
        }
        return .ok(.proposalsDecided(DecisionDTO(
            decided: ids.filter(known.contains), skipped: skipped, cards: dtos,
            summary: "Created \(cards.count) Backlog card(s). Nothing was filed on GitHub — "
                + "moving a card from backlog to todo is what does that."
        )))
    }
```

- [x] **Step 5: Update the one construction site**

In `ElliotKit/Sources/ElliotApp/AppModel.swift`, `startIPC(board:store:)` now needs the service. Change its signature to `startIPC(board:store:analysis:)` and the handler line to:

```swift
            let handler = MCPRequestHandler(store: store, board: board, analysis: analysis)
```

The `AnalysisService` instance is created in `start()` in Task 13; until then, construct it inline just above the `startIPC` call:

```swift
            let analysisService = AnalysisService(
                store: store, launcher: scheduler, board: board, gh: ghClient
            )
            self.analysisService = analysisService
            startIPC(board: board, store: store, analysis: analysisService)
```

and add the stored property `private var analysisService: AnalysisService?`.

- [x] **Step 6: Run the tests and commit**

```bash
cd ElliotKit && swift test && cd ..
git add ElliotKit/Sources/ElliotIPC ElliotKit/Sources/ElliotApp ElliotKit/Tests/ElliotIPCTests
git commit -m "feat(ipc): carry analyses, proposals and decisions over the socket

Angles cross the wire as strings so an unknown one is an error message
naming the six, rather than a decode failure that loses the request and
explains nothing.

The protocol version moves to 2: a helper in an older bundle meeting this
app must fail loudly on hello, which is the whole point of the constant.

A proposal DTO carries `grounded` rather than raw booleans per file — an
agent deciding what to accept needs to know whether the claim was
checkable, and the per-file detail belongs in the window."
```

---

### Task 12: The four MCP tools

**Files:**
- Modify: `ElliotKit/Sources/ElliotMCPKit/ElliotMCPServer.swift`
- Test: `ElliotKit/Tests/ElliotIPCTests/AnalysisWireTests.swift` (add the tool-shape test to the existing suite)

**Interfaces:**
- Consumes: everything from Task 11.
- Produces: tools `board_analyze_repo`, `board_list_proposals`, `board_accept_proposals`, `board_reject_proposals`.

**The read/write split, unchanged:** `board_list_proposals` is a read, so it falls back to the read-only database snapshot when Elliot is down, annotated `offline-db`. The other three are writes and go through the running app. `ElliotMCPKit` still imports neither `ElliotEngine` nor `ElliotProcess`.

- [x] **Step 1: Write the failing test**

Add to `AnalysisWireTests.swift` — a new suite in the same file so the wire and its MCP face are read together:

```swift
import ElliotMCPKit

@Suite("Analysis MCP tools")
struct AnalysisMCPToolTests {

    private func tool(_ name: String) -> MCP.Tool? {
        ElliotMCPServer.tools.first { $0.name == name }
    }

    @Test("The four analysis tools are declared", arguments: [
        "board_analyze_repo", "board_list_proposals",
        "board_accept_proposals", "board_reject_proposals",
    ])
    func toolsExist(name: String) {
        #expect(tool(name) != nil)
    }

    @Test("Only listing proposals is a read")
    func readOnlyHints() {
        #expect(tool("board_list_proposals")?.annotations.readOnlyHint == true)
        #expect(tool("board_analyze_repo")?.annotations.readOnlyHint == false)
        #expect(tool("board_accept_proposals")?.annotations.readOnlyHint == false)
    }

    /// The descriptions are the only thing an agent reads before acting. Two
    /// facts must be in them or it will guess wrong.
    @Test("The descriptions say an analysis is slow and that accepting files nothing")
    func descriptionsCarryTheTwoFactsThatMatter() throws {
        let analyze = try #require(tool("board_analyze_repo")?.description.lowercased())
        #expect(analyze.contains("minute"))
        #expect(analyze.contains("board_list_runs"))

        let accept = try #require(tool("board_accept_proposals")?.description.lowercased())
        #expect(accept.contains("backlog"))
        #expect(accept.contains("github"))
    }

    @Test("Every angle is offered in the schema")
    func schemaEnumeratesAngles() throws {
        let analyze = try #require(tool("board_analyze_repo"))
        let json = try #require(String(data: WireCodec.encoder.encode(analyze.inputSchema), encoding: .utf8))
        for angle in AnalysisAngle.allCases {
            #expect(json.contains(angle.rawValue))
        }
    }
}
```

Add `import MCP` and `import ElliotMCPKit` at the top of the file, and add `"ElliotMCPKit"` and the MCP product to the `ElliotIPCTests` target's dependencies in `Package.swift`:

```swift
        .testTarget(
            name: "ElliotIPCTests",
            dependencies: ["ElliotIPC", "ElliotMCPKit", .product(name: "MCP", package: "swift-sdk")]
        ),
```

The MCP product is named explicitly rather than relied on transitively: the
test writes `import MCP` to name `Tool`, and a transitive import working is a
build-system detail, not a guarantee.

- [x] **Step 2: Run test to verify it fails**

Run: `cd ElliotKit && swift test --filter AnalysisMCPToolTests`
Expected: FAIL — the four tools are missing.

- [x] **Step 3: Declare the tools in `ElliotMCPServer.swift`**

Append to the `tools` array:

```swift
        Tool(
            name: "board_analyze_repo",
            description: """
                Read a repository through one or more lenses and propose user \
                stories. Each angle is its own `claude -p` run and takes minutes; \
                this returns as soon as the runs are queued. Poll board_list_runs \
                to follow them, then board_list_proposals to read what they found. \
                Proposals are not cards: nothing reaches the board until \
                board_accept_proposals is called.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "repo": .object([
                        "type": .string("string"),
                        "description": .string("Repository as owner/name, or an absolute path."),
                    ]),
                    "angles": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("string"),
                            "enum": .array(AnalysisAngle.allCases.map { .string($0.rawValue) }),
                        ]),
                        "description": .string(
                            "One run per angle. bugs = defects; quickWins = high value for one "
                            + "sitting; features = capabilities the code is asking for; "
                            + "techDebt = structure costing something now; tests = uncovered "
                            + "invariants; docsAndDX = friction a newcomer hits."
                        ),
                    ]),
                    "max_stories": .object([
                        "type": .string("integer"),
                        "description": .string("Cap per angle, 1–30."),
                        "default": .int(8),
                    ]),
                    "instructions": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Extra direction folded into every angle's prompt, e.g. "
                            + "\"concentrate on the process layer\"."
                        ),
                    ]),
                ]),
                "required": .array([.string("repo"), .string("angles")]),
            ]),
            annotations: .init(title: "Analyse a repository", readOnlyHint: false, destructiveHint: false)
        ),
        Tool(
            name: "board_list_proposals",
            description: """
                List the user stories an analysis proposed. Give either \
                analysis_id or repo. `grounded` is false when a story cites a \
                file that is not there — it may still be right, but it was not \
                checkable. `duplicate_hint` flags a story that looks like \
                something already on the board or already filed.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "analysis_id": .object(["type": .string("string")]),
                    "repo": .object(["type": .string("string")]),
                    "status": .object([
                        "type": .string("string"),
                        "enum": .array(ProposalStatus.allCases.map { .string($0.rawValue) }),
                        "default": .string("proposed"),
                    ]),
                    "limit": .object(["type": .string("integer"), "default": .int(100)]),
                ]),
            ]),
            annotations: .init(title: "List proposals", readOnlyHint: true)
        ),
        Tool(
            name: "board_accept_proposals",
            description: """
                Turn proposals into Backlog cards. This files nothing on GitHub: \
                a card in Backlog runs nothing, and moving it to `todo` is what \
                opens an issue. Proposals already accepted or rejected are \
                skipped rather than duplicated.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "proposal_ids": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                ]),
                "required": .array([.string("proposal_ids")]),
            ]),
            annotations: .init(title: "Accept proposals", readOnlyHint: false, destructiveHint: false)
        ),
        Tool(
            name: "board_reject_proposals",
            description: """
                Mark proposals as rejected. They stay on the analysis so it still \
                reads as what it found, including what was turned down.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "proposal_ids": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                ]),
                "required": .array([.string("proposal_ids")]),
            ]),
            annotations: .init(title: "Reject proposals", readOnlyHint: false, destructiveHint: false)
        ),
```

- [x] **Step 4: Dispatch them**

Add to `call(name:arguments:)`:

```swift
            case "board_analyze_repo": return try await analyzeRepo(args)
            case "board_list_proposals": return try await listProposals(args)
            case "board_accept_proposals": return try await decideProposals(args, accept: true)
            case "board_reject_proposals": return try await decideProposals(args, accept: false)
```

And the implementations, after `listRuns`:

```swift
    private func analyzeRepo(_ args: [String: Value]) async throws -> CallTool.Result {
        guard let repo = args["repo"]?.stringValue else {
            return Self.error(code: "bad_argument", message: "repo is required.")
        }
        let angles = args["angles"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard !angles.isEmpty else {
            return Self.error(
                code: "bad_argument",
                message: "angles must list at least one lens.",
                hint: "One of: \(AnalysisAngle.allCases.map(\.rawValue).joined(separator: ", "))."
            )
        }

        let response = bridge.write(.analyzeRepo(
            repo: repo,
            angles: angles,
            maxStories: args["max_stories"]?.intValue ?? 8,
            instructions: args["instructions"]?.stringValue ?? ""
        ))
        return Self.render(response) { payload in
            guard case .analysisStarted(let analysis) = payload else { return nil }
            return [
                "analysis_id": .string(analysis.id.uuidString),
                "repo": .string(analysis.repo),
                "runs": Self.encode(analysis.runs),
                "note": .string(
                    "Each run takes minutes. Poll board_list_runs, then "
                    + "board_list_proposals with this analysis_id."
                ),
            ]
        }
    }

    private func listProposals(_ args: [String: Value]) async throws -> CallTool.Result {
        let analysisID = args["analysis_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        let repo = args["repo"]?.stringValue
        guard analysisID != nil || repo != nil else {
            return Self.error(
                code: "bad_argument", message: "Give either analysis_id or repo."
            )
        }
        // Default to what still needs deciding: an agent asking "what did the
        // analysis find" means the open ones.
        let status = args["status"]?.stringValue ?? ProposalStatus.proposed.rawValue
        let limit = args["limit"]?.intValue ?? 100

        switch bridge.read(.listProposals(
            analysisID: analysisID, repo: repo, status: status, limit: limit
        )) {
        case .live(let response):
            return Self.render(response) { payload in
                guard case .proposals(let proposals) = payload else { return nil }
                return ["proposals": Self.encode(proposals), "source": .string("live")]
            }
        case .offline(let store):
            let repos = try await store.repos()
            let match = repo.flatMap { name in
                repos.first { $0.nameWithOwner == name || $0.path == name }
            }
            let proposals = try await store.proposals(
                analysisID: analysisID,
                repoID: match?.id,
                status: ProposalStatus(rawValue: status),
                limit: limit
            )
            let dtos = proposals.map { proposal in
                ProposalDTO(
                    proposal: proposal,
                    repoName: repos.first { $0.id == proposal.repoID }?.nameWithOwner ?? "?"
                )
            }
            return Self.ok([
                "proposals": Self.encode(dtos),
                "source": .string("offline-db"),
                "note": .string("Elliot is not running; this is a snapshot of its database."),
            ])
        }
    }

    private func decideProposals(_ args: [String: Value], accept: Bool) async throws -> CallTool.Result {
        let ids = (args["proposal_ids"]?.arrayValue ?? [])
            .compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) }
        guard !ids.isEmpty else {
            return Self.error(code: "bad_argument", message: "proposal_ids must contain UUIDs.")
        }
        let response = bridge.write(
            accept ? .acceptProposals(ids: ids) : .rejectProposals(ids: ids)
        )
        return Self.render(response) { payload in
            guard case .proposalsDecided(let decision) = payload else { return nil }
            var fields: [String: Value] = [
                "decided": .array(decision.decided.map { .string($0.uuidString) }),
                "summary": .string(decision.summary),
            ]
            if !decision.skipped.isEmpty {
                fields["skipped"] = .array(decision.skipped.map { .string($0.uuidString) })
            }
            if !decision.cards.isEmpty {
                fields["cards"] = Self.encode(decision.cards)
            }
            return fields
        }
    }
```

- [x] **Step 5: Run the tests and commit**

```bash
cd ElliotKit && swift test && cd ..
git add ElliotKit/Sources/ElliotMCPKit ElliotKit/Package.swift ElliotKit/Tests/ElliotIPCTests
git commit -m "feat(mcp): analyse, read the proposals, accept or reject

Listing proposals is a read and answers from the read-only snapshot when
Elliot is down, annotated offline-db, like every other read. The other
three go through the running app.

The descriptions carry the two facts an agent will otherwise guess wrong:
an analysis takes minutes and returns immediately, and accepting files
nothing on GitHub — a Backlog card runs nothing, moving it to To Do does.

ElliotMCPKit still imports neither ElliotEngine nor ElliotProcess. It
holds no analysis logic, exactly as it holds no move rules."
```

---

### Task 13: The Analysis window

**Files:**
- Create: `ElliotKit/Sources/ElliotApp/AnalysisWindow.swift`
- Modify: `ElliotKit/Sources/ElliotApp/AppModel.swift`
- Modify: `ElliotKit/Sources/ElliotApp/BoardView.swift:35-63`

**Interfaces:**
- Consumes: `AnalysisService` (Task 9), `BoardStore.observeProposals(analysisID:)` and `.runs(analysisID:)` (Task 6).
- Produces: `AppModel.showingAnalysis`, `.activeAnalysisID`, `.analysisRuns`, `.proposals`, `.analysisNote`, `.startAnalysis(repoID:angles:instructions:maxStories:)`, `.openAnalysis(id:)`, `.acceptProposals(ids:)`, `.rejectProposals(ids:)`, `.updateProposal(_:)`, `.recentAnalyses()`; `AnalysisWindow`, `ProposalEditor`.

**One window, not two sheets.** It opens in setup and, once running, the *same* window lists the runs at the top and fills in with proposals as each angle lands. That is what makes one run per angle worth its cost: the quick wins are readable and sortable while the bugs angle is still working.

- [x] **Step 1: Add the state and actions to `AppModel.swift`**

Add the observable properties beside the existing ones:

```swift
    public var showingAnalysis = false
    /// The analysis the window is showing. `nil` means it is still in setup.
    public private(set) var activeAnalysisID: UUID?
    public private(set) var analysisRuns: [SkillRun] = []
    public private(set) var proposals: [StoryProposal] = []
    /// Whatever the window needs to say about the last action.
    public private(set) var analysisNote: String?
```

And a private field beside `observationTasks`:

```swift
    private var proposalObservation: Task<Void, Never>?
```

Add the actions, in a new `// MARK: - Analysis` section:

```swift
    public func startAnalysis(
        repoID: UUID, angles: [AnalysisAngle], instructions: String, maxStories: Int
    ) async {
        guard let analysisService else { return }
        do {
            let started = try await analysisService.start(
                repoID: repoID, angles: angles, extraInstructions: instructions,
                maxStoriesPerAngle: maxStories, origin: .manual
            )
            analysisNote = nil
            openAnalysis(id: started.analysis.id)
        } catch {
            analysisNote = error.localizedDescription
        }
    }

    public func openAnalysis(id: UUID) {
        activeAnalysisID = id
        proposals = []
        analysisRuns = []
        Task { await refreshAnalysisRuns() }

        // Proposals arrive run by run, so the list fills in as each angle
        // lands rather than all at once when the last one does.
        proposalObservation?.cancel()
        guard let store else { return }
        let observation = store.observeProposals(analysisID: id)
        proposalObservation = Task { [weak self] in
            do {
                for try await proposals in observation {
                    await MainActor.run { self?.proposals = proposals }
                }
            } catch {
                await MainActor.run { self?.analysisNote = error.localizedDescription }
            }
        }
    }

    public func closeAnalysis() {
        proposalObservation?.cancel()
        proposalObservation = nil
        activeAnalysisID = nil
        analysisRuns = []
        proposals = []
        analysisNote = nil
    }

    public func refreshAnalysisRuns() async {
        guard let store, let id = activeAnalysisID else { return }
        analysisRuns = (try? await store.runs(analysisID: id)) ?? []
    }

    public func recentAnalyses() async -> [Analysis] {
        guard let store else { return [] }
        return (try? await store.analyses(repoID: selectedRepoID, limit: 20)) ?? []
    }

    public func updateProposal(_ proposal: StoryProposal) async {
        try? await analysisService?.updateProposal(proposal)
    }

    public func acceptProposals(ids: [UUID]) async {
        guard let analysisService else { return }
        do {
            let cards = try await analysisService.accept(proposalIDs: ids)
            analysisNote = cards.isEmpty
                ? "Nothing to accept — those were already decided."
                : "Added \(cards.count) card(s) to Backlog. Nothing was filed on GitHub."
        } catch {
            analysisNote = error.localizedDescription
        }
    }

    public func rejectProposals(ids: [UUID]) async {
        try? await analysisService?.reject(proposalIDs: ids)
        analysisNote = "Rejected \(ids.count) proposal(s)."
    }

    /// The angles still working, for the window's header.
    public var runningAngles: [AnalysisAngle] {
        analysisRuns.filter { !$0.state.isTerminal }.compactMap(\.analysisAngle)
    }
```

In `apply(_:)`, keep the window's run list live — an analysis run's `cardID` is nil, so the existing card refresh does not cover it:

```swift
        case .runStarted(let runID, _):
            liveLog[runID] = ["▸ started"]
            Task { await self.refreshAnalysisRuns() }
```

and in the `.runFinished` case, after the existing card refresh:

```swift
            Task { await self.refreshAnalysisRuns() }
```

In `shutdown()`, add `proposalObservation?.cancel()`.

- [x] **Step 2: Add the toolbar entry in `BoardView.swift`**

After the "New story" button, before `Spacer()`:

```swift
            Button {
                model.showingAnalysis = true
            } label: {
                Label("Analyze…", systemImage: "sparkle.magnifyingglass")
            }
            .disabled(model.selectedRepoID == nil || isSelectedRepoBlocked)
            .help(model.selectedRepoID == nil
                ? "Pick a single repository to analyse."
                : "Read this repository through several lenses and propose stories.")
```

Add the helper below `chooseRepository()`:

```swift
    /// Analysis is refused for the same repositories cards are: a blocked repo
    /// would fail at the first run anyway, and saying so here is cheaper.
    private var isSelectedRepoBlocked: Bool {
        guard let id = model.selectedRepoID, let repo = model.repos.first(where: { $0.id == id })
        else { return true }
        return !repo.isEnabled || model.isBlocked(repo)
    }
```

And attach the window as a sheet, beside the two existing ones:

```swift
        .sheet(isPresented: $model.showingAnalysis) {
            AnalysisWindow()
        }
```

- [x] **Step 3: Write `AnalysisWindow.swift`**

```swift
import ElliotEngine
import ElliotModel
import SwiftUI

/// One window that starts as a form and becomes a review list.
///
/// Deliberately not two sheets: once the runs are going, the proposals appear
/// under them angle by angle. Splitting them would hide the thing that makes
/// one run per angle worth paying for — the quick wins are triable while the
/// bugs angle is still reading.
struct AnalysisWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var angles: Set<AnalysisAngle> = [.bugs, .quickWins]
    @State private var instructions = ""
    @State private var maxStories = 8
    @State private var selection: Set<UUID> = []
    @State private var editing: StoryProposal?
    @State private var past: [Analysis] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()

            if model.activeAnalysisID == nil {
                setup
            } else {
                running
            }

            if let note = model.analysisNote {
                Text(note).font(.callout).foregroundStyle(.secondary)
            }

            Divider()
            footer
        }
        .padding(16)
        .frame(width: 720, height: 640)
        .sheet(item: $editing) { proposal in
            ProposalEditor(proposal: proposal)
        }
        .task { past = await model.recentAnalyses() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Analyze \(repoName)").font(.title2.bold())
            Spacer()
            if !past.isEmpty, model.activeAnalysisID == nil {
                Menu("Past analyses") {
                    ForEach(past) { analysis in
                        Button(label(for: analysis)) { model.openAnalysis(id: analysis.id) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private var repoName: String {
        model.repos.first { $0.id == model.selectedRepoID }?.displayName ?? "…"
    }

    private func label(for analysis: Analysis) -> String {
        let when = analysis.createdAt.formatted(date: .abbreviated, time: .shortened)
        let lenses = analysis.angles.map(\.symbol).joined()
        return "\(when)  \(lenses)"
    }

    // MARK: - Setup

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Each angle is its own run. Pick the ones you want — they cost a full read of the repository each.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                ForEach(AnalysisAngle.allCases, id: \.self) { angle in
                    Toggle(isOn: binding(for: angle)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(angle.symbol)  \(angle.title)")
                            Text(angle.briefing)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Stepper("At most \(maxStories) stories per angle", value: $maxStories, in: 1...30)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Anything else to steer it").font(.caption.bold())
                    TextEditor(text: $instructions)
                        .font(.body)
                        .frame(height: 70)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                }
            }
        }
    }

    private func binding(for angle: AnalysisAngle) -> Binding<Bool> {
        Binding(
            get: { angles.contains(angle) },
            set: { $0 ? angles.insert(angle) : angles.remove(angle) }
        )
    }

    // MARK: - Running and reviewing

    private var running: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.analysisRuns) { run in
                HStack(spacing: 8) {
                    Text(run.analysisAngle?.symbol ?? "•")
                    Text(run.analysisAngle?.title ?? "run").frame(width: 110, alignment: .leading)
                    if run.state.isTerminal {
                        Text(run.state.rawValue).font(.caption).foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    if let report = run.analysisReport {
                        Text("\(report.kept) kept").font(.caption).foregroundStyle(.secondary)
                        if !report.dropped.isEmpty {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .help(report.dropped.joined(separator: "\n"))
                        }
                        if report.harvestSource == .resultText {
                            Text("recovered from the reply")
                                .font(.caption).foregroundStyle(.orange)
                                .help("No artifact was written; the stories were salvaged from the closing message.")
                        }
                        if report.workingTreeChanged {
                            Label("edited the repo", systemImage: "exclamationmark.octagon")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .help(report.workingTreeDiff ?? "")
                        }
                    }
                    Spacer()
                    if !run.state.isTerminal {
                        Button("Cancel") { Task { await model.cancelRun(id: run.id) } }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
            }

            Divider()
            proposalList
        }
    }

    private var proposalList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(AnalysisAngle.allCases, id: \.self) { angle in
                    let group = model.proposals.filter { $0.angle == angle && $0.status == .proposed }
                    if !group.isEmpty {
                        Text("\(angle.symbol)  \(angle.title.uppercased())  (\(group.count))")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        ForEach(group) { proposal in
                            row(proposal)
                        }
                    }
                }
                if model.proposals.allSatisfy({ $0.status != .proposed }), !model.analysisRuns.isEmpty {
                    Text(model.runningAngles.isEmpty
                        ? "Nothing left to decide."
                        : "Waiting on \(model.runningAngles.map(\.title).joined(separator: ", "))…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            }
        }
    }

    private func row(_ proposal: StoryProposal) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(
                get: { selection.contains(proposal.id) },
                set: { $0 ? selection.insert(proposal.id) : selection.remove(proposal.id) }
            ))
            .labelsHidden()

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(proposal.title).font(.body.weight(.medium))
                    Text(proposal.effort.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                    Spacer()
                    Button("Edit") { editing = proposal }
                        .buttonStyle(.borderless).font(.caption)
                }
                Text(proposal.story.narrative).font(.caption).foregroundStyle(.secondary)

                if !proposal.story.acceptanceCriteria.isEmpty {
                    Text("✓ \(proposal.story.acceptanceCriteria.count) criteria")
                        .font(.caption2).foregroundStyle(.secondary)
                        .help(proposal.story.acceptanceCriteria.joined(separator: "\n"))
                }
                if !proposal.rationale.isEmpty {
                    Text(proposal.rationale).font(.caption2).foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    ForEach(proposal.evidence, id: \.self) { evidence in
                        // Struck through when the file is not there: the
                        // fastest way to see a story that was invented.
                        Text(evidence.display)
                            .font(.caption2.monospaced())
                            .strikethrough(!evidence.exists)
                            .foregroundStyle(evidence.exists ? .secondary : .red)
                            .help(evidence.exists ? "" : "This file is not in the repository.")
                    }
                }
                if let hint = proposal.duplicateOf?.label {
                    Label(hint, systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if model.activeAnalysisID != nil {
                Text("\(selection.count) selected").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close", role: .cancel) {
                model.closeAnalysis()
                dismiss()
            }
            if model.activeAnalysisID == nil {
                Button("Start") {
                    guard let repoID = model.selectedRepoID else { return }
                    Task {
                        await model.startAnalysis(
                            repoID: repoID,
                            angles: AnalysisAngle.allCases.filter(angles.contains),
                            instructions: instructions,
                            maxStories: maxStories
                        )
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(angles.isEmpty || model.selectedRepoID == nil)
            } else {
                Button("Reject") {
                    let ids = Array(selection)
                    selection = []
                    Task { await model.rejectProposals(ids: ids) }
                }
                .disabled(selection.isEmpty)

                Button("→ Backlog (\(selection.count))") {
                    let ids = Array(selection)
                    selection = []
                    Task { await model.acceptProposals(ids: ids) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty)
            }
        }
    }
}

/// Correcting a proposal before it becomes a card.
///
/// The point of editing here rather than after: the corrected story is what
/// reaches the board, so a nearly-right proposal is worth keeping instead of
/// rejecting and retyping.
struct ProposalEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var draft: StoryProposal
    @State private var criteria: [String]

    init(proposal: StoryProposal) {
        _draft = State(initialValue: proposal)
        _criteria = State(initialValue: proposal.story.acceptanceCriteria.isEmpty
            ? [""]
            : proposal.story.acceptanceCriteria)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit proposal").font(.title2.bold())

            TextField("Board label", text: $draft.title).textFieldStyle(.roundedBorder)
            LabeledContent("As a") {
                TextField("developer", text: $draft.story.role).textFieldStyle(.roundedBorder)
            }
            LabeledContent("I want") {
                TextField("", text: $draft.story.want).textFieldStyle(.roundedBorder)
            }
            LabeledContent("So that") {
                TextField("", text: $draft.story.benefit).textFieldStyle(.roundedBorder)
            }

            Text("Acceptance criteria").font(.caption.bold()).padding(.top, 4)
            ForEach(criteria.indices, id: \.self) { index in
                HStack {
                    TextField("…", text: Binding(
                        get: { criteria.indices.contains(index) ? criteria[index] : "" },
                        set: { if criteria.indices.contains(index) { criteria[index] = $0 } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Button {
                        criteria.remove(at: index)
                        if criteria.isEmpty { criteria = [""] }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button("Add criterion", systemImage: "plus") { criteria.append("") }
                .buttonStyle(.borderless).font(.caption)

            Spacer()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    var edited = draft
                    edited.story.acceptanceCriteria = criteria
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    Task {
                        await model.updateProposal(edited)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.story.isComplete || draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 560, height: 520)
    }
}
```

- [x] **Step 4: Build and check the app runs**

```bash
cd ElliotKit && swift build --product ElliotApp && cd ..
./Scripts/build-app.sh
open dist/Elliot.app
```

Expected: the board opens; the *Analyze…* button is enabled once a repository is selected and its preflight is green.

If `Evidence` does not satisfy `ForEach(_:id:\.self)`, it is already `Hashable` from Task 1 — check the `import ElliotModel`.

- [x] **Step 5: Run the suite and commit**

```bash
cd ElliotKit && swift test && cd ..
git add ElliotKit/Sources/ElliotApp
git commit -m "feat(app): one window that starts as a form and becomes a review list

Not two sheets: once the runs are going the proposals appear under them
angle by angle, which is the thing that makes one run per angle worth
paying for — quick wins are triable while the bugs angle is still reading.

Evidence whose file is missing is struck through, because that is the
fastest way to see a story that was invented rather than found. And a
proposal is editable before acceptance: the corrected story is what
reaches the board, so a nearly-right one is worth keeping rather than
rejecting and retyping."
```

---

### Task 14: Documentation, and checking it against a real repository

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/plans/2026-08-05-repo-analysis.md` (tick the boxes as you go)

**Interfaces:** none — this task ships the feature.

- [x] **Step 1: Update the README**

After the "The board" section, add:

```markdown
## Where stories come from

The backlog holds user stories, and Elliot can write them. *Analyze…* reads a
registered repository through six lenses — bugs, quick wins, features, tech
debt, tests, docs & DX — one `claude -p` run each, and comes back with proposed
stories you go through and accept.

Proposals are **not cards**. They live in their own table and their own window,
so a 30-story analysis does not drown the board and the five columns keep one
meaning. Accepting calls the same `BoardService.createCard` the New Card sheet
uses, and the card lands in Backlog, where nothing runs.

The same four steps are available over MCP: `board_analyze_repo`,
`board_list_proposals`, `board_accept_proposals`, `board_reject_proposals`.
```

Then add to "Decisions worth knowing":

```markdown
**The artifact is the fact.** There is no `gh` to appeal to about whether a
story is a good idea — the agent's judgement *is* the deliverable. So the
analogue of "`gh` is the fact" is a file: each run is told to write
`stories.json` at a path announced in its own prompt, and Elliot reads that
rather than the closing message. The path is marked `ELLIOT_OUTPUT=`, and a
property test asserts every prompt carries exactly one and that it is absolute
— the same class of invariant as the first digit run of an `implement-issue`
prompt. If the file is missing, the last fenced JSON block in the reply is
tried, and which source answered is recorded on the run.

**Evidence, checked.** Every proposed story must cite `file:line`. Elliot
resolves each citation against the repository and confines it there, so a
proposal whose files do not exist is shown struck through. It is the only
objective fact available about an opinion, and it is the fastest way to see a
story that was invented rather than found.

**An analysis cannot be stopped from writing, so it is watched.** No CLI flag
expresses "Write, but only under this path". The prompt forbids touching the
repository, `--add-dir` makes the scratch directory writable, and `git status
--porcelain` is compared before and after. A run that edited your code is
reported, not guessed at.
```

Update "Status" — move the analysis out of "not done" and note what is still unproven:

```markdown
Not done: registering a repository is UI-only (no CLI), the merge path has not
been exercised against a real pull request, the `.app` is ad-hoc signed rather
than notarised, and the analysis has been proven end to end only against the
fake `claude` — no real repository has been read yet.
```

- [x] **Step 2: Full verification**

```bash
cd ElliotKit && swift test && cd ..
./Scripts/build-app.sh
```

Expected: every test passes, and `dist/Elliot.app` is assembled.

- [ ] **Step 3: Check it against this repository, for real**

This is the step the fake `claude` cannot do. It costs tokens and reads real code; it files nothing on GitHub.

1. Launch `dist/Elliot.app` **from the Finder**, so the PATH capture is exercised the way it will be in use.
2. Register `/Users/philippe/repo/gh-phmatray/Elliot` and get its preflight green (run the `repo.profile` fix if it is red).
3. *Analyze…* → tick **Quick wins** only, cap 5 → Start.
4. Watch: the run appears, streams, and finishes. Then check by hand:

```bash
ls ~/Library/Application\ Support/Elliot/analyses/*/*/stories.json
```

Expected: the artifact exists and is a JSON array. If it does not, the window will already say `recovered from the reply` or show the dropped reasons — which is the design working, but note it: if the artifact path turns out to be the common failure, the spec's risk 1 has fired and the fenced-block path should become primary.

5. In the window: the proposals are grouped, each cites a file, and the citations are **not** struck through. A struck-through citation on a repository you know well is the signal to distrust that story.
6. Accept one. It appears in Backlog. Nothing happened on GitHub — confirm:

```bash
gh issue list --repo phmatray/Elliot --limit 5
```

7. From Claude Code, with the helper registered:
   - "list the proposals from my last Elliot analysis" → `board_list_proposals` answers.
   - Quit Elliot, ask again → the answer is annotated `offline-db`.
   - Ask to accept one → Elliot relaunches and the card appears.

- [x] **Step 4: Commit the documentation**

```bash
git add README.md docs/superpowers/plans/2026-08-05-repo-analysis.md
git commit -m "docs: where stories come from

Records the three decisions worth knowing about the analysis: the
artifact is the fact where there is no gh to appeal to; evidence is
resolved rather than believed; and a run that edits the repository is
watched for, because it cannot be prevented.

Status stays honest: the analysis is proven end to end against the fake
claude only. No real repository has been read yet."
```

---

## Self-review notes

Checked against the spec, section by section:

| Spec section | Task |
|---|---|
| Decisions table | 1–13 (each row is a task's rationale) |
| Model — angle, two story shapes, analysis, `SkillRun` | 1, 5 |
| Shared text similarity | 2 |
| Prompt and artifact, the two invariants | 3 |
| Harvest — read, decode, resolve, hint, persist | 4, 7 |
| Scheduling table, own lane, dedupe key | 8, 9 |
| Git sentinel | 8 (baseline + compare), 10 (proof) |
| Analysis window | 13 |
| MCP and IPC | 11, 12 |
| Storage, migration `v2_analysis` | 6 |
| Testing — every named suite | 1–4, 6–10, 12 |
| Out of scope | not implemented, deliberately |
| Risks 1–5 | 7 (harvest source recorded), 3 (cost shown), 4 (sentinel), 5 (`githubTitlesAvailable`) |

Two things this plan adds that the spec left implicit, both because a task
would otherwise have had a hole in it: `SkillRun.analysisAngle` (the window
lists runs by angle and the dedupe key needs it) and `AnalysisRunReport` as a
single nullable column rather than four loose ones.
