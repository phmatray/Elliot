import ElliotModel
import Foundation

/// What Preflight says about a repository, asked at the moment of the act.
///
/// A protocol rather than a `PreflightService` parameter for two reasons. A test
/// can state a verdict instead of running six subprocesses and a networked
/// `gh label list` for it; and the services that consult it cannot each grow
/// their own idea of what a failing check means, because there is one
/// implementation of the real answer and it is ``PreflightGate``.
///
/// ⛔ **The answer is a `PreflightState`, never a `Bool`.** `PreflightService`
/// once had `isBlocking(_:) -> Bool`, read through `repoChecks[id] ?? []` — so a
/// repository nobody had swept answered `false`, and *not asked* and *asked and
/// clear* were one value. That is how a gate three separate documents claimed
/// existed turned out never to have been written, and it is why the function was
/// deleted in #302 rather than kept as a wrapper. Reintroducing a `Bool` here
/// would put the same shape back one layer up: a gate that cannot say *nobody
/// looked* has to say *fine*.
public protocol RepoGating: Sendable {

    /// Preflight's verdict on this repository, right now.
    ///
    /// Asked live, every time. A cached verdict is the shape of bug this exists
    /// to close: the cache belongs to a screen that may never have been opened,
    /// and an unattended agent must not start on a reading nobody took.
    func verdict(for repo: Repo) async -> PreflightState
}

/// The real gate.
///
/// `PreflightService.repoChecks` folded into a verdict by ``PreflightReading`` —
/// the same type the Preflight screen's rows are judged by, not a second reading
/// of the same facts.
///
/// ⚠️ **It never answers ``PreflightState/notChecked``**, and that is a property
/// of `PreflightReading` rather than an omission here: a reading *is* somebody
/// having looked. The third state belongs to a caller that did not ask.
///
/// It costs roughly six subprocesses and one network call per start. That is the
/// price of asking rather than assuming, and it is paid once per gesture that
/// can spawn up to eight unattended `claude -p` runs at `bypassPermissions`
/// inside a real checkout.
public struct PreflightGate: RepoGating {
    private let preflight: PreflightService

    public init(preflight: PreflightService) {
        self.preflight = preflight
    }

    public func verdict(for repo: Repo) async -> PreflightState {
        PreflightReading(results: await preflight.repoChecks(repo), checkedAt: Date()).verdict
    }
}

/// A gate that has not looked.
///
/// For a caller that has already decided, and for tests — which say so out loud
/// with this type rather than by omitting an argument. `RepoGating` has no
/// default anywhere for that reason: a defaulted gate compiles at every site and
/// catches none of them.
///
/// ⚠️ **It answers ``PreflightState/notChecked``, not `passing`, and the
/// difference is the whole subject of this file.** It refuses nothing *today*,
/// because `UnattendedStartRefusal` lets `notChecked` through for the reasons
/// `PreflightState` writes out. What it must not do is claim a sweep happened —
/// `passing` here would be a caller saying *asked and clear* having asked
/// nothing, planted in the one type whose name invites it.
///
/// The consequence is deliberate: the day `notChecked` starts refusing — which
/// `PreflightState` says is one line in `evaluateMove` — every site holding one
/// of these starts refusing too, and has to state a verdict it has measured.
/// That is the loud direction. `passing` would leave them all silently
/// permitting a change that was meant to stop them.
public struct OpenGate: RepoGating {
    public init() {}

    public func verdict(for repo: Repo) async -> PreflightState { .notChecked }
}
