import ElliotModel
import Foundation

/// Bumped whenever the wire format changes. A helper embedded in an old app
/// bundle meeting a newer app fails loudly on `hello` rather than misbehaving
/// halfway through a move.
///
/// 2 — repository analysis: `analyzeRepo`, `listProposals`, `acceptProposals`,
///     `rejectProposals`.
public let elliotProtocolVersion = 2

public enum ElliotRequest: Codable, Sendable {
    case hello(protocolVersion: Int, token: String, client: String)
    case listCards(repo: String?, column: ElliotModel.Column?, limit: Int)
    case getCard(id: UUID)
    case createCard(repo: String, title: String, body: String, story: StoryInput?, column: ElliotModel.Column)
    case moveCard(id: UUID, to: ElliotModel.Column, followUps: [String])
    case listRuns(cardID: UUID?, limit: Int)
    /// Angles arrive as strings so an unknown one is a clear error message
    /// rather than a decoding failure that loses the whole request.
    case analyzeRepo(repo: String, angles: [String], maxStories: Int, instructions: String)
    case listProposals(analysisID: UUID?, repo: String?, status: String?, limit: Int)
    case acceptProposals(ids: [UUID])
    case rejectProposals(ids: [UUID])

    /// The three parts of a user story, separately — so a skill generating
    /// stories from a repository can fill them in rather than hand over prose
    /// that would have to be parsed back apart.
    public struct StoryInput: Codable, Sendable {
        public var role: String
        public var want: String
        public var benefit: String
        public var acceptanceCriteria: [String]

        public init(role: String, want: String, benefit: String, acceptanceCriteria: [String] = []) {
            self.role = role
            self.want = want
            self.benefit = benefit
            self.acceptanceCriteria = acceptanceCriteria
        }

        public var story: UserStory {
            UserStory(role: role, want: want, benefit: benefit, acceptanceCriteria: acceptanceCriteria)
        }
    }
}

public enum ElliotErrorCode: String, Codable, Sendable {
    case appUnavailable = "app_unavailable"
    case protocolMismatch = "protocol_mismatch"
    case unauthorized
    case cardNotFound = "card_not_found"
    case repoNotFound = "repo_not_found"
    case moveBlocked = "move_blocked"
    case readOnly = "read_only"
    case internalError = "internal_error"
    case analysisNotFound = "analysis_not_found"
    case proposalNotFound = "proposal_not_found"
    case unknownAngle = "unknown_angle"
    case analysisRefused = "analysis_refused"
}

public enum ElliotResponse: Codable, Sendable {
    case ok(ElliotPayload)
    case failure(code: ElliotErrorCode, message: String, hint: String?)
}

public enum ElliotPayload: Codable, Sendable {
    case hello(serverVersion: String)
    case cards([CardDTO])
    case card(CardDTO)
    case moved(MoveDTO)
    case runs([RunDTO])
    case analysisStarted(AnalysisDTO)
    case proposals([ProposalDTO])
    case proposalsDecided(DecisionDTO)
}

// MARK: - Wire shapes
//
// Deliberately not the model types: what an agent reads should stay stable and
// self-describing even as the storage schema moves.

public struct CardDTO: Codable, Sendable, Hashable {
    public var id: UUID
    public var title: String
    public var column: String
    public var repo: String
    public var story: StoryDTO?
    public var body: String?
    public var issueNumber: Int?
    public var issueURL: String?
    public var prNumber: Int?
    public var prURL: String?
    public var branch: String?
    public var lastError: String?
    /// Set when the card is held by a run, which is why a move would be refused.
    public var activeRunID: UUID?

    public struct StoryDTO: Codable, Sendable, Hashable {
        public var role: String
        public var want: String
        public var benefit: String
        public var acceptanceCriteria: [String]
        public var narrative: String

        public init(_ story: UserStory) {
            role = story.role
            want = story.want
            benefit = story.benefit
            acceptanceCriteria = story.acceptanceCriteria
            narrative = story.narrative
        }
    }

    public init(card: Card, repoName: String, activeRunID: UUID? = nil) {
        id = card.id
        title = card.displayTitle
        column = card.column.rawValue
        repo = repoName
        story = card.story.map(StoryDTO.init)
        body = card.body.isEmpty ? nil : card.body
        issueNumber = card.issueNumber
        issueURL = card.issueURL
        prNumber = card.prNumber
        prURL = card.prURL
        branch = card.branch
        lastError = card.lastError
        self.activeRunID = activeRunID
    }
}

public struct MoveDTO: Codable, Sendable, Hashable {
    public var cardID: UUID
    public var from: String
    public var to: String
    /// The run the move started, if it triggered one.
    public var runID: UUID?
    public var triggered: String?
    /// Plain-language account of what the move did, for the agent to relay.
    public var summary: String

    public init(cardID: UUID, from: String, to: String, runID: UUID?, triggered: String?, summary: String) {
        self.cardID = cardID
        self.from = from
        self.to = to
        self.runID = runID
        self.triggered = triggered
        self.summary = summary
    }
}

public struct RunDTO: Codable, Sendable, Hashable {
    public var id: UUID
    public var cardID: UUID?
    public var kind: String
    public var state: String
    public var prompt: String
    public var startedAt: Date?
    public var endedAt: Date?
    public var totalCostUSD: Double?
    public var resultText: String?
    public var permissionDenials: [String]
    public var logPath: String

    public init(run: SkillRun) {
        id = run.id
        cardID = run.cardID
        kind = run.kind.rawValue
        state = run.state.rawValue
        prompt = run.prompt
        startedAt = run.startedAt
        endedAt = run.endedAt
        totalCostUSD = run.totalCostUSD
        resultText = run.resultText
        permissionDenials = run.permissionDenials
        logPath = run.logPath
    }
}

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

// MARK: - Framing

/// One request or response per line of JSON, correlated by `id`.
public struct Envelope<Body: Codable & Sendable>: Codable, Sendable {
    public var id: UUID
    public var body: Body

    public init(id: UUID = UUID(), body: Body) {
        self.id = id
        self.body = body
    }
}

public enum WireCodec {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Foundation's JSONEncoder does not otherwise promise a stable key
        // order between two calls that encode the same keys — sortedKeys
        // makes the wire format byte-for-byte reproducible, which the
        // analysis round-trip tests rely on and which is a reasonable
        // property for a wire protocol to have regardless.
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func encodeLine<T: Codable & Sendable>(_ value: T) throws -> Data {
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Codable & Sendable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}
