import ElliotModel
import Foundation

/// The queue as a reader sees it: whether it is stopped, and what is holding
/// each thing in it.
///
/// A second protocol beside `RunLaunching`, which declares only `launch` and
/// `cancel`. An unattended session has to tell a run the *board* is waiting on
/// from a run the *scheduler* is holding — `.paused`, `.dailyCeilingReached` and
/// `.mergeWaitsForRepoToBeIdle` are a hand on the brake, not the world moving —
/// and a report that confused them would send the reader to fix the wrong thing.
///
/// Methods rather than `async` properties: `queueSnapshot()` already has exactly
/// this shape on the actor, so it witnesses this unchanged.
public protocol RunQueueReading: Sendable {
    /// Whether every pending run is being held by the user's own stop.
    func queueIsPaused() async -> Bool
    /// The pending queue, in the order `pump()` will consider it, each entry
    /// carrying the rule that is holding it.
    func queueSnapshot() async -> [QueuedRun]
}
