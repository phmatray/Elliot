import Foundation

/// What a repository does instead of what a standard expects, filed onto the
/// card an agent will read. `expected`/`actual` are short enough to sit on a
/// card without truncating; `fixHint` is optional because not every axis has
/// one worth writing (a licence choice has no one-liner, an `.editorconfig`
/// gap does).
public struct Violation: Sendable, Hashable {
    public var summary: String
    public var expected: String
    public var actual: String
    public var fixHint: String?

    public init(summary: String, expected: String, actual: String, fixHint: String? = nil) {
        self.summary = summary
        self.expected = expected
        self.actual = actual
        self.fixHint = fixHint
    }
}

/// What one axis says about one repository — five cases, deliberately never a
/// `Bool`.
///
/// `.unmeasured` is first-class rather than folded into either neighbour:
/// folded up into `.compliant` it hides a rate limit behind a green counter;
/// folded down into `.violating` it files a card for a repository nobody
/// managed to look at. Same argument as `RepoIssue.unlisted`
/// (`ElliotModel/RepoReconciliation.swift`) — a row claiming "fine" when the
/// honest answer is "I could not check" is the one thing this codebase spends
/// its effort refusing to do.
///
/// `.exempt` carries the `Exemption` that silenced the axis, rather than being
/// folded into `.compliant` with a note: a caller asking "does this pass" and
/// a caller asking "why is there no card" are asking different questions, and
/// only the second one needs to read a reason and a grantor.
public enum StandardVerdict: Sendable, Hashable {
    case compliant(detail: String)
    case violating(Violation)
    case notApplicable(NotApplicable)
    case unmeasured(Unmeasured)
    case exempt(Exemption)

    /// The only question the card emitter may ask. There is deliberately no
    /// `isCompliant`: every caller that wants one wants it `true` for four of
    /// the five cases, and `.unmeasured` is not one of them — a convenience
    /// accessor here is exactly how a rate limit turns into a filed card.
    public var producesCard: Bool {
        if case .violating = self { return true }
        return false
    }

    /// Whether this verdict may sit on either side of a compliance ratio.
    /// `.notApplicable` and `.unmeasured` are excluded so a ratio can never be
    /// inflated by a failure to look — the denominator only grows when the
    /// axis was actually judged, whichever way it went.
    public var countsInDenominator: Bool {
        switch self {
        case .compliant, .violating, .exempt: return true
        case .notApplicable, .unmeasured: return false
        }
    }
}

/// A verdict, together with what was consulted to reach it.
///
/// One type rather than a tuple, because both halves are load-bearing and both
/// were originally missing: `provenances` is what `StandardFinding.observationLag`
/// reduces over, so a short list silently under-reports a verdict's age, and
/// `evidence` is what makes the finding judgeable at all.
///
/// The rule for both fields is the same and it is honesty: list **what was
/// actually consulted**, never everything that was available. A fork returns at
/// the scope step without reading the exemptions file, so its outcome must not
/// claim it did.
public struct StandardOutcome: Sendable, Hashable {
    public var verdict: StandardVerdict
    public var provenances: [Provenance]
    public var evidence: [Evidence]

    public init(
        verdict: StandardVerdict, provenances: [Provenance], evidence: [Evidence] = []
    ) {
        self.verdict = verdict
        self.provenances = provenances
        self.evidence = evidence
    }
}

/// One axis's verdict for one repository, and everything it rests on.
public struct StandardFinding: Identifiable, Sendable, Hashable {
    public var id: String  // "phmatray/Foo#editorconfig"
    public var nameWithOwner: String
    public var standard: Standard
    public var verdict: StandardVerdict
    public var evidence: [Evidence]
    /// Every observation this verdict actually consulted.
    public var provenances: [Provenance]
    public var assessedAt: Date

    public init(
        id: String,
        nameWithOwner: String,
        standard: Standard,
        verdict: StandardVerdict,
        evidence: [Evidence],
        provenances: [Provenance],
        assessedAt: Date
    ) {
        self.id = id
        self.nameWithOwner = nameWithOwner
        self.standard = standard
        self.verdict = verdict
        self.evidence = evidence
        self.provenances = provenances
        self.assessedAt = assessedAt
    }

    /// How stale the OLDEST input was when the predicate ran. A verdict can
    /// rest on several observations of different ages — the tree three hours
    /// ago, a workflow body a day ago, the exemptions file two minutes ago —
    /// and reporting the youngest is how a verdict resting on a day-old
    /// workflow reads as two minutes fresh.
    public var observationLag: TimeInterval {
        guard let oldest = provenances.map(\.observedAt).min() else { return 0 }
        return assessedAt.timeIntervalSince(oldest)
    }

    /// How old this VERDICT is now — a different question, and the one a
    /// reader of a stored row is actually asking. `observationLag` is fixed at
    /// the moment the predicate ran; this keeps moving with `now`, because a
    /// row nothing has overwritten since August must not read as fresh in
    /// November just because its own inputs once were.
    public func staleness(at now: Date) -> TimeInterval {
        now.timeIntervalSince(assessedAt)
    }
}

/// The card a violation deserves — the story, the rubric, the expected/actual
/// pair and every command that observed it, filed once so the agent that
/// picks up the card does not have to re-derive any of it.
///
/// Declared here (rather than left for the task that first produces one)
/// because `RepoStandardsAssessment.seeds` needs a concrete element type now:
/// a placeholder here would mean a breaking rename the moment a card is
/// actually built.
public struct StandardCardSeed: Sendable, Hashable {
    public var idempotencyKey: String
    public var nameWithOwner: String
    public var standard: Standard
    public var title: String
    public var story: UserStory
    public var body: String
    public var evidence: [Evidence]

    public init(
        idempotencyKey: String,
        nameWithOwner: String,
        standard: Standard,
        title: String,
        story: UserStory,
        body: String,
        evidence: [Evidence]
    ) {
        self.idempotencyKey = idempotencyKey
        self.nameWithOwner = nameWithOwner
        self.standard = standard
        self.title = title
        self.story = story
        self.body = body
        self.evidence = evidence
    }
}

/// Every axis's verdict for one repository, gathered under one clock reading.
public struct RepoStandardsAssessment: Sendable, Hashable {
    public var nameWithOwner: String
    public var findings: [StandardFinding]
    public var seeds: [StandardCardSeed]
    public var assessedAt: Date

    public init(
        nameWithOwner: String,
        findings: [StandardFinding],
        seeds: [StandardCardSeed],
        assessedAt: Date
    ) {
        self.nameWithOwner = nameWithOwner
        self.findings = findings
        self.seeds = seeds
        self.assessedAt = assessedAt
    }
}
