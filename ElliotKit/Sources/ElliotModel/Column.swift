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

    /// Where a card in this column goes when it advances one step.
    ///
    /// `nil` for `.done`: a done card has nowhere to go, which is what keeps it
    /// out of "what should I do next" without a second list of exclusions.
    ///
    /// Read off `allCases` rather than written out, so board order and this one
    /// step cannot come to disagree.
    public var naturalNext: Column? {
        let order = Self.allCases
        guard let index = order.firstIndex(of: self), index + 1 < order.count else { return nil }
        return order[index + 1]
    }
}

public extension Column {
    /// Position in board order, so "forward" is comparable. Ranking uses it to
    /// put work that is nearly done above work that has barely started, and the
    /// GitHub import uses it to move a card on only when the computed column is
    /// strictly later than the one it sits in.
    ///
    /// Read off `allCases`, which is declared in board order, so this cannot
    /// drift from what the user sees.
    var boardIndex: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}
