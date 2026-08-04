import ElliotModel
import Foundation

/// Bumped whenever the wire format changes. A helper embedded in an old app
/// bundle meeting a newer app fails loudly on `hello` rather than misbehaving
/// halfway through a move.
public let elliotProtocolVersion = 1

public enum ElliotRequest: Codable, Sendable {
    case hello(protocolVersion: Int, token: String, client: String)
    case listCards(repo: String?, column: ElliotModel.Column?, limit: Int)
    case getCard(id: UUID)
    case createCard(repo: String, title: String, body: String, story: StoryInput?, column: ElliotModel.Column)
    case moveCard(id: UUID, to: ElliotModel.Column, followUps: [String])
    case listRuns(cardID: UUID?, limit: Int)

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
    public var cardID: UUID
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
