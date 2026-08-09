import ElliotModel
import Foundation
import GRDB

// The model types stay free of GRDB: persistence conformance is added here, so
// `ElliotModel` remains a dependency-free island that the rule engine and its
// tests can rely on.
//
// UUIDs are stored as uppercase text rather than GRDB's default 16-byte blob.
// Two processes share this file and a human occasionally opens it with the
// `sqlite3` CLI to see why a card is stuck; a readable key is worth the extra
// bytes. Note the strategy is a *function* in GRDB 7 — declaring it as a
// `static var` compiles but is silently ignored, which stores blobs while every
// lookup asks for text.

extension Repo: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "repo"
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .uppercaseString
    }
}

extension Card: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "card"
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .uppercaseString
    }

    public enum Columns {
        public static let id = GRDB.Column("id")
        public static let repoID = GRDB.Column("repoID")
        public static let column = GRDB.Column("column")
        public static let orderIndex = GRDB.Column("orderIndex")
        public static let issueNumber = GRDB.Column("issueNumber")
        public static let prNumber = GRDB.Column("prNumber")
        public static let idempotencyKey = GRDB.Column("idempotencyKey")
        /// When the card entered the column it is in. For a finished card that
        /// is when it landed, which is what the archive orders on.
        public static let columnEnteredAt = GRDB.Column("columnEnteredAt")
    }
}

extension SkillRun: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "skillRun"
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .uppercaseString
    }

    public enum Columns {
        public static let id = GRDB.Column("id")
        public static let cardID = GRDB.Column("cardID")
        public static let repoID = GRDB.Column("repoID")
        public static let analysisID = GRDB.Column("analysisID")
        public static let state = GRDB.Column("state")
        public static let createdAt = GRDB.Column("createdAt")
    }
}

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
        /// The lens run that landed the row — which is what makes "has this run
        /// already been harvested?" a query rather than a guess (#330).
        public static let runID = GRDB.Column("runID")
        public static let status = GRDB.Column("status")
        public static let createdAt = GRDB.Column("createdAt")
    }
}

extension MoveAudit: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "moveAudit"
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .uppercaseString
    }

    public enum Columns {
        public static let cardID = GRDB.Column("cardID")
        public static let at = GRDB.Column("at")
    }
}

/// A `(repo, issue|pr, number)` the user dismissed. Not a model type: nothing
/// outside the store needs the timestamp.
///
/// The UUID strategy is not optional here — `repo.id` is stored as uppercase
/// text, so a `repoID` written as GRDB's default blob would match no repository
/// and the `ON DELETE CASCADE` would never fire.
struct DismissalRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "dismissedExternal"
    static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .uppercaseString
    }

    var repoID: UUID
    var kind: String
    var number: Int
    var dismissedAt: Date
}

/// The UUID strategy carries the same weight as `DismissalRecord`'s: `repo.id`
/// is uppercase text, so a `repoID` written as GRDB's default blob would match
/// no repository and the `ON DELETE CASCADE` would silently never fire — leaving
/// statuses for repositories that no longer exist.
extension PRStatus: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "prStatus"
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .uppercaseString
    }

    public enum Columns {
        public static let repoID = GRDB.Column("repoID")
        public static let prNumber = GRDB.Column("prNumber")
    }
}

/// `Column` means the board's five columns everywhere in Elliot. GRDB's SQL
/// `Column` is reached through this alias so the unqualified name keeps the
/// meaning that matters to the domain.
public typealias SQLColumn = GRDB.Column

/// A database key for a model id, matching the encoding strategy above.
extension UUID {
    var databaseKey: String { uuidString.uppercased() }
}
