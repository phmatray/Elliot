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
        public static let state = GRDB.Column("state")
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

/// `Column` means the board's five columns everywhere in Elliot. GRDB's SQL
/// `Column` is reached through this alias so the unqualified name keeps the
/// meaning that matters to the domain.
public typealias SQLColumn = GRDB.Column

/// A database key for a model id, matching the encoding strategy above.
extension UUID {
    var databaseKey: String { uuidString.uppercased() }
}
