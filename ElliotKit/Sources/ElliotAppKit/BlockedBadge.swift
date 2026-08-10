import ElliotEngine
import Foundation

/// One check, on one repository: what Preflight holds a disclosure open under,
/// and what a card's badge points at.
///
/// ⛔ **Composite because `CheckResult.id` is not unique on that screen.** Every
/// repository produces `repo.exists`, `repo.clean`, `repo.labels` … so a
/// dictionary keyed on the check alone opens and closes the same row on *every*
/// repository at once. That is what shipped until #298, and with one repository
/// registered it looks exactly like working code.
///
/// `repoID` is optional because the machine-wide checks belong to no repository.
/// Their ids (`tool.gh`, `env.loginShell`, `mcp.socket`) come from a different
/// producer than the per-repository ones, so the two families cannot collide.
struct CheckAddress: Hashable {
    var repoID: UUID?
    var checkID: String
}

/// What a card says when its repository will not let it move, and where pressing
/// it goes.
///
/// One value rather than a `Bool` beside a title beside an id: the sentence is
/// only true because the repository is refused, and the destination is only
/// meaningful for the check that refused it. ``AppModel/blockedBadge(for:)`` is
/// the only thing that makes one, so a card cannot draw this without a verdict
/// and cannot draw a verdict without somewhere to send the reader.
struct BlockedBadge: Hashable {

    /// The repository whose Preflight section this opens.
    let repoID: UUID

    /// The check that failed, when a sweep has actually named one.
    ///
    /// ⚠️ **`nil` is a real state, not a defensive one.** `Repo.preflight` is
    /// persisted and the readings are not, so between launch and the first sweep
    /// landing, a repository that failed last session refuses moves with nothing
    /// in memory to name the reason. The badge is drawn from the same verdict
    /// `BoardService.proposeMove` reads, so in that window it says *that* the
    /// card cannot move while it cannot yet say why. Drawing nothing instead —
    /// which is what shipped, because the badge read the in-memory checks — is a
    /// card that looks movable and is not.
    let check: CheckResult?

    /// The line on the card.
    ///
    /// Deliberately **not** `Consequence.reason(.repoBlocked)`, which is what a
    /// *refused gesture* says. That sentence explains something the reader has
    /// just tried; this labels a standing state and is itself a control. The two
    /// are kept apart for the reason `.repoDisabled` and `.repoBlocked` are kept
    /// apart one file over — and `RefusalWordingTests` already holds a pair like
    /// this from drifting into one voice read twice.
    var sentence: String {
        guard let check else { return "Repository blocked — see Preflight" }
        return "Blocked: \(check.title)"
    }

    /// Where the disclosure lives that pressing this opens.
    var address: CheckAddress? {
        check.map { CheckAddress(repoID: repoID, checkID: $0.id) }
    }

    /// The tooltip, and the name of the accessibility action.
    ///
    /// One home for both: the card is `.accessibilityElement(children: .combine)`,
    /// so the badge's own button is invisible to assistive technology and the
    /// act has to be exposed separately. Two hand-written strings for one act is
    /// how a tooltip and a VoiceOver label come to name different things.
    var openHint: String {
        check.map { "Show \($0.title) in Preflight" } ?? "Show this repository in Preflight"
    }
}
