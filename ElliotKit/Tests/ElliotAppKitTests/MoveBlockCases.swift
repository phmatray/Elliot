import ElliotModel
import Foundation

/// Every `MoveBlock`, held to the enum by the compiler.
///
/// `MoveBlock` carries associated values, so it is not `CaseIterable` and the
/// literal lists this replaces could fall behind the enum in total silence —
/// which is what they did: adding a case broke four `switch`es in `Sources` and
/// nothing at all in three test files that claimed to cover "every block".
///
/// The loop is closed in both directions. `of(_:)` switches over `MoveBlock`
/// with **no `default:`**, so a case added to the model stops this target
/// compiling; its arms can only return a `MoveBlockCase`, so the shadow has to
/// grow too; and `allCases` then makes `allBlocks` grow by itself. A new case
/// therefore cannot reach a green suite unnamed.
enum MoveBlockCase: CaseIterable {
    case sameColumn
    case emptyIdea
    case incompleteStory
    case missingIssueNumber
    case missingPRNumber
    case repoDisabled
    case repoBlocked
    case runAlreadyInFlight
    case notVerifiedGreen
    case systemOwnedTransition

    /// One value standing for this case. The associated values are arbitrary —
    /// what is under test is the wording of a case, never of a payload.
    var sample: MoveBlock {
        switch self {
        case .sameColumn: .sameColumn
        case .emptyIdea: .emptyIdea
        case .incompleteStory: .incompleteStory
        case .missingIssueNumber: .missingIssueNumber
        case .missingPRNumber: .missingPRNumber
        case .repoDisabled: .repoDisabled
        case .repoBlocked: .repoBlocked
        case .runAlreadyInFlight: .runAlreadyInFlight(runID: UUID())
        case .notVerifiedGreen: .notVerifiedGreen(reason: .sign(.checksFailing(count: 1)))
        case .systemOwnedTransition: .systemOwnedTransition
        }
    }

    /// Exhaustive over `MoveBlock`, with no `default:`. This arm is the guard;
    /// everything else in this file is bookkeeping around it.
    static func of(_ block: MoveBlock) -> MoveBlockCase {
        switch block {
        case .sameColumn: .sameColumn
        case .emptyIdea: .emptyIdea
        case .incompleteStory: .incompleteStory
        case .missingIssueNumber: .missingIssueNumber
        case .missingPRNumber: .missingPRNumber
        case .repoDisabled: .repoDisabled
        case .repoBlocked: .repoBlocked
        case .runAlreadyInFlight: .runAlreadyInFlight
        case .notVerifiedGreen: .notVerifiedGreen
        case .systemOwnedTransition: .systemOwnedTransition
        }
    }

    static var allBlocks: [MoveBlock] { allCases.map(\.sample) }
}
