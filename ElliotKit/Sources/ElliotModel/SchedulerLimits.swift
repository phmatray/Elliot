import Foundation

/// How many runs Elliot is allowed to have going at once.
///
/// These were `let` constants on `RunScheduler`'s initialiser and nothing ever
/// passed anything else, so the only way to run more than two skills in parallel
/// was to edit Swift and rebuild — on a control room pointed at a portfolio of
/// several hundred repositories.
///
/// Here rather than on the scheduler because a limit is a rule, and a rule in an
/// actor's stored property cannot be validated, persisted or tested on its own.
public struct SchedulerLimits: Codable, Sendable, Equatable {
    /// Runs that write: create-issue, implement-issue, merge-pr.
    ///
    /// The cap exists to keep two *builds* out of one `.build/`, which is why
    /// analyses are counted separately below — an analysis only reads.
    public var maxConcurrent: Int
    public var maxConcurrentAnalyses: Int

    /// What shipped before this was configurable. Kept as the default so an
    /// existing store, which has no saved value, behaves exactly as it did.
    public static let `default` = SchedulerLimits(maxConcurrent: 2, maxConcurrentAnalyses: 3)

    /// Above this the machine is the bottleneck, not the limit: each writer run
    /// is a `claude` process that builds. The ceiling is a guard against a
    /// fat-fingered stepper, not a considered maximum.
    public static let ceiling = 12

    /// Clamped rather than rejected. This is a preference, not a command: a
    /// caller that asks for zero workers means "as few as possible", and
    /// refusing would leave the stored value at whatever it was while the
    /// caller believed it had changed.
    public init(maxConcurrent: Int, maxConcurrentAnalyses: Int) {
        self.maxConcurrent = Self.clamp(maxConcurrent)
        self.maxConcurrentAnalyses = Self.clamp(maxConcurrentAnalyses)
    }

    static func clamp(_ value: Int) -> Int {
        min(max(value, 1), ceiling)
    }

    /// Written out rather than synthesised, because the synthesised one assigns
    /// the properties directly and **skips the clamp above**.
    ///
    /// That is not theoretical tidiness: these live in a SQLite file as JSON, so
    /// an older build, a bad merge or a hand edit can put anything there, and
    /// `{"maxConcurrent": 400}` would admit four hundred concurrent `claude`
    /// processes. The clamp has to be on the way in from disk, not only on the
    /// way in from the stepper.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            maxConcurrent: try container.decode(Int.self, forKey: .maxConcurrent),
            maxConcurrentAnalyses: try container.decode(Int.self, forKey: .maxConcurrentAnalyses)
        )
    }
}
