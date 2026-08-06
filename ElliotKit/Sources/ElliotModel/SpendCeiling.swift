import Foundation

/// The most Elliot may spend, per run and per day.
///
/// On this board a drag spawns an unattended agent under `bypassPermissions`,
/// and until this existed there was no upper bound on what a gesture cost. The
/// stream decoder already recognised `error_max_budget_usd` — Claude Code knows
/// how to stop on a budget — and Elliot simply never set one. Raising the worker
/// count without this multiplies the speed of a meter with no brake.
///
/// Both halves are optional and default to off, because a ceiling nobody chose
/// is a ceiling that will stop a legitimate `merge-pr` at 3 a.m. and look like a
/// bug.
public struct SpendCeiling: Codable, Sendable, Equatable {
    /// Handed to Claude Code as `--max-budget-usd`, so the run stops itself.
    /// This is the only half that can bound a *single* runaway run: nothing on
    /// our side can interrupt a process mid-turn.
    public var perRunUSD: Double?

    /// Enforced by us, at admission. Claude Code cannot know what its siblings
    /// have already spent today.
    public var perDayUSD: Double?

    public static let off = SpendCeiling(perRunUSD: nil, perDayUSD: nil)

    /// A ceiling of zero would refuse everything forever, which reads as the app
    /// being broken rather than as a setting. Treated as "no ceiling", the same
    /// way the steppers treat zero workers as one.
    public init(perRunUSD: Double?, perDayUSD: Double?) {
        self.perRunUSD = Self.sanitise(perRunUSD)
        self.perDayUSD = Self.sanitise(perDayUSD)
    }

    static func sanitise(_ value: Double?) -> Double? {
        guard let value, value > 0, value.isFinite else { return nil }
        return value
    }

    /// Written out rather than synthesised: the synthesised `init(from:)` skips
    /// the sanitising above, and these are persisted as JSON in a file that an
    /// older build or a hand edit can put anything into. The same trap
    /// `SchedulerLimits` fell into, caught there by a test.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            perRunUSD: try container.decodeIfPresent(Double.self, forKey: .perRunUSD),
            perDayUSD: try container.decodeIfPresent(Double.self, forKey: .perDayUSD)
        )
    }

    /// Whether today's spend has reached the daily ceiling.
    ///
    /// `>=`, not `>`: at the ceiling the budget is spent, and admitting one more
    /// run would put the day over it by whatever that run costs.
    public func daylimitReached(spentToday: Double) -> Bool {
        guard let perDayUSD else { return false }
        return spentToday >= perDayUSD
    }
}
