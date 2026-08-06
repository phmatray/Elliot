import Foundation

/// The one place that decides what giving up on a child means.
///
/// Both spawners need the same two-rung stop — SIGTERM, then SIGKILL for a
/// child that ignores it — and both had it, written twice, with two different
/// grace periods: 5 s in `ProcessRunner`, 15 s in `StreamingProcess`. Neither
/// number was wrong on its own; having two of them was, because the two
/// spawners then disagreed about when a process is hopeless and only one of
/// them could be right. One rule, one implementation.
public enum ProcessTermination {

    /// How long a child gets between the ask and the kill.
    ///
    /// Changing it changes both spawners, which is the point. It is 15 s
    /// because that is what `StreamingProcess` shipped with; if the number is
    /// wrong it is wrong in both places, and moving it is a deliberate act
    /// rather than a side effect of touching one caller.
    public static let hardKillGrace: Duration = .seconds(15)

    /// Asks `process` to stop, escalating to SIGKILL if it is still alive after
    /// `grace`.
    ///
    /// Returns as soon as the SIGTERM is sent; the escalation is a backstop
    /// running behind it, never something a caller waits on. A child that takes
    /// the hint therefore costs nothing — it is already gone when the backstop
    /// wakes, `isAlive` says so, and no second signal is sent.
    ///
    /// `isAlive` rather than a bare `process.isRunning` because the caller can
    /// answer it under the same lock that publishes the child's exit. Testing
    /// `isRunning` and then killing is two steps with a reaped pid possible in
    /// between, and a pid the kernel has recycled belongs to somebody else by
    /// the time the signal lands.
    static func terminate(
        _ process: Process,
        hardKillAfter grace: Duration = hardKillGrace,
        isAlive: @escaping @Sendable () -> Bool
    ) {
        guard isAlive() else { return }
        process.terminate()

        Task.detached {
            try? await Task.sleep(for: grace)
            guard isAlive() else { return }
            kill(process.processIdentifier, SIGKILL)
        }
    }
}
