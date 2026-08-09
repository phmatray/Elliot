import ElliotModel
import Foundation

/// One repository's checks, and the fact that somebody actually ran them.
///
/// ⛔ **This type exists so that "nobody looked" cannot be spelled `[]`.**
/// `PreflightService.isBlocking(_:)` was `results.contains { $0.status == .fail }`,
/// and both of its callers reached it through `repoChecks[id] ?? []` — so an
/// unswept repository answered `false`, which reads as *fine*. That is the
/// two-valued answer to a three-valued question `PreflightState` was introduced
/// for one layer down, still being given one layer up: the rule engine could say
/// `notChecked` and the screen could not.
///
/// A reading cannot be built without the moment it was taken at, and an
/// **absent** reading is the third state. ``verdict(of:)`` is the one place that
/// fold happens, for the reason `Repo.preflightVerdict` is one property rather
/// than four `?? .notChecked` coalescings.
public struct PreflightReading: Sendable, Hashable {

    /// The checks, in the order `PreflightService.repoChecks` produced them.
    public let results: [CheckResult]

    /// When they were run.
    ///
    /// Carried rather than inferred because the screen shows it: a verdict from
    /// twenty minutes ago drawn exactly like one from a second ago is the same
    /// silence this type removes, one dimension over.
    public let checkedAt: Date

    public init(results: [CheckResult], checkedAt: Date) {
        self.results = results
        self.checkedAt = checkedAt
    }

    /// The check that stops this repository's cards moving, or `nil`.
    ///
    /// The **first** failing one, in the service's own order — which runs from
    /// "is this a git repository at all" outwards, so the first failure is the
    /// one the others are most likely downstream of. A card has room for one
    /// sentence, and this is the one worth spending it on.
    public var blocking: CheckResult? {
        results.first { $0.status == .fail }
    }

    /// What this reading says about moving a card.
    ///
    /// Never `.notChecked`: a reading *is* somebody having looked.
    public var verdict: PreflightState {
        blocking == nil ? .passing : .failing
    }

    /// The verdict of a reading that may not exist.
    ///
    /// The whole mistake this type is about is a caller that says "passing" by
    /// omission, so the absent case is folded in exactly once, here.
    public static func verdict(of reading: PreflightReading?) -> PreflightState {
        reading?.verdict ?? .notChecked
    }
}
