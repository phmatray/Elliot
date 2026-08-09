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
    /// `small` | `medium` | `large`; anything else is recorded as unstated.
    public var effort: String

    public init(
        title: String,
        role: String,
        want: String,
        benefit: String,
        acceptanceCriteria: [String] = [],
        rationale: String = "",
        evidence: [String] = [],
        effort: String = ""
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
        effort = try container.decodeIfPresent(String.self, forKey: .effort) ?? ""
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
    /// The model said nothing an effort could be read out of.
    ///
    /// Its own case rather than a fold onto `.medium`: "somebody sized this as
    /// medium" and "nobody sized this" are different facts, and only the first
    /// one may feed a queue that engages cards with nobody watching. `.medium`
    /// survives as a size a model can state, never as one Elliot invents.
    case unstated

    /// Anything unrecognised becomes `.unstated`. A wrong size is a nuisance; a
    /// size nobody chose, presented as one somebody did, is worse than either.
    public static func parse(_ raw: String) -> Effort {
        Effort(rawValue: raw.trimmed().lowercased()) ?? .unstated
    }
}

public extension Effort {
    /// What this size is worth: cheaper is worth more, because the queue is
    /// spending a whole unattended agent per card either way.
    ///
    /// Data, like `AnalysisAngle.valueWeight`, and beside its own type so a new
    /// size cannot reach the score without somebody choosing a number for it.
    var valueWeight: Double {
        switch self {
        case .small: 1.0
        case .medium: 0.6
        case .large: 0.3
        // Unreachable from `CardValue.of`, which refuses an unstated effort
        // rather than scoring it. Zero rather than a plausible middle so that a
        // caller that scores it anyway gets an obviously wrong answer.
        case .unstated: 0.0
        }
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
///
/// ⚠️ **Persisted as JSON on `StoryProposal.duplicateOf`, so the cases are
/// additive and never renamed.** Swift's synthesised enum coding writes
/// `{"card":{…}}`, one key per case, so a row written before a case existed
/// still decodes — but a *renamed* case makes every row carrying the old name
/// unreadable, and shipped rows cannot be migrated by a schema change.
public enum DuplicateHint: Codable, Sendable, Hashable {
    case card(id: UUID, title: String)
    case issue(number: Int, title: String)
    /// Another proposal from the **same analysis**, under another lens.
    ///
    /// Runs are per lens and land independently, so Bugs and Tech debt reading
    /// the same file routinely propose the same change — and the panel groups
    /// by angle, which puts the two copies in different sections of a list that
    /// holds up to eight lenses' worth. Accept both and the board grows two
    /// cards, each of which later spawns its own unattended `create-issue`
    /// against the same work (#295).
    ///
    /// ⚠️ **One-directional by construction.** A run can only be scored against
    /// siblings already written, so the *first* lens to land never carries this
    /// and the later one always does. The label says "already proposed" for
    /// that reason: worded symmetrically it would claim a pairing that only
    /// one of the two rows knows about.
    ///
    /// The lens travels with it because the lens is the section heading — it is
    /// how the reader finds the row this one looks like.
    case proposal(id: UUID, title: String, angle: AnalysisAngle)

    public var label: String {
        switch self {
        case .card(_, let title):
            "looks like the card \u{201C}\(title)\u{201D}"
        case .issue(let number, let title):
            "looks like issue #\(number) — \(title)"
        case .proposal(_, let title, let angle):
            "looks like \u{201C}\(title)\u{201D}, already proposed by the \(angle.title) lens"
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
        // `.unstated`, never `.medium`: this is public API, so "no live path
        // omits it today" is a statement about today. `AnalysisService.accept`
        // copies `effort` onto the card *and* sets `appraisedAt`, so a caller
        // that omitted the argument would produce a card `CardValue.of` ranks
        // on a size nobody chose — the one failure this type exists to prevent,
        // arriving through the last door left open.
        effort: Effort = .unstated,
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

    /// What this proposal's citations turned out to be worth.
    public var grounding: Grounding {
        Grounding.of(evidence: evidence)
    }

    /// True when every cited file was found. The fastest signal that a story
    /// was found rather than invented.
    ///
    /// A reader of `grounding`, not a second definition of it: the panel's seal
    /// and the wire's `grounded` flag both come through here, and a copy of the
    /// `allSatisfy` would be free to drift the first time either is corrected.
    public var isGrounded: Bool {
        grounding == .grounded
    }

    /// Whether the harvest thought this collides with something that already
    /// exists — a card, an open issue, or a sibling lens's proposal.
    ///
    /// Beside ``isGrounded`` because the panel offers the same gesture for
    /// both: *select every row that looks like this*, so a bulk decision is one
    /// click away. ⚠️ **Selecting is not deciding.** See ``duplicateOf`` — this
    /// is a courtesy, and a bulk *Reject* of the flagged rows would be the
    /// refusal this type says it is not.
    public var looksDuplicated: Bool { duplicateOf != nil }

    /// Whether the *Rejected* list should offer to put this one back.
    ///
    /// ⚠️ **A hint, in this board's own sense of the word — the fact is the
    /// store's conditional `UPDATE`.** A view cannot be atomic, so this is read
    /// to decide what to *draw*; `BoardStore.claimProposal(id:_:)` is what
    /// decides whether the row actually moves, and its refusal is what the
    /// panel's note reports when the two disagree. Deriving the button from
    /// here and the outcome from there is the same split as `duplicateOf`
    /// beside `gh`, not a second answer to one question.
    ///
    /// `acceptedCardID` is the load-bearing half: a proposal that already
    /// produced a Backlog card must never re-enter the triage list, or the next
    /// Accept makes a second card for one story.
    ///
    /// ⛔ **It is not a complete guard against that, and the gap is worth
    /// knowing.** The reject race `AnalysisService.reject` documents could
    /// leave a row `.rejected` with `acceptedCardID` **nil** while its card sits
    /// on the board — the backlink was what the losing write wiped. Nothing on
    /// the card points back at the proposal, so that row is indistinguishable
    /// from an ordinary rejection and this returns `true` for it. The race is
    /// fixed; rows written before the fix are not recoverable from here.
    public var isRestorable: Bool {
        status == .rejected && acceptedCardID == nil
    }
}
