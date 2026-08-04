import Foundation

/// The five board columns, in board order.
///
/// The raw values are persisted, so they are part of the on-disk contract:
/// renaming a case requires a migration.
public enum Column: String, Codable, CaseIterable, Sendable, Hashable {
    case backlog
    case todo
    case inProgress
    case inReview
    case done

    public var displayName: String {
        switch self {
        case .backlog: "Backlog"
        case .todo: "To Do"
        case .inProgress: "In Progress"
        case .inReview: "In Review"
        case .done: "Done"
        }
    }
}
