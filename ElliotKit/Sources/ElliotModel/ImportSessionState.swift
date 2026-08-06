import Foundation

/// Which repositories have been brought in from GitHub this session, and which
/// could not be.
///
/// This exists because the guard it replaces stored *one* fact where there were
/// two. `AppModel` inserted the repository id into a `Set` **before** awaiting
/// the import, so "we tried" and "we succeeded" became the same record — and
/// since `GitHubImportService` folds every error into `ImportSummary.failure`
/// rather than throwing, a repository Elliot could not reach was marked done
/// for the rest of the session. The board then showed it with no cards, which
/// is the same screen as a repository that genuinely has no open work.
///
/// The principle is the one PR #104 settled for clone verdicts: **an unknown is
/// not an OK.** A row that says "fine" when the real answer is "I could not
/// check" is a non-measurement rendered as a pass.
///
/// So three facts are kept apart:
///
/// - **succeeded** — absorbing. Nothing asks again this session; that is the
///   once-per-session guard #17 wanted and it is preserved exactly.
/// - **attempted** — spent by *any* outcome. This is what bounds the unattended
///   path, so a repository that fails while `gh` is down cannot produce a second
///   unattended `gh` call however often the view re-evaluates.
/// - **failed** — the message, kept until the repository succeeds or is
///   forgotten, so the failure outlives `status`, which the next event
///   overwrites.
///
/// Pure: no I/O, no clock. In `ElliotModel` because it is a rule, not because
/// the app target is unreachable — since #72 it is not.
public struct ImportSessionState: Codable, Sendable, Hashable {

    /// Repositories whose import completed with no failure.
    private var succeeded: Set<UUID> = []

    /// Repositories the unattended path has already spent its one attempt on,
    /// whatever the outcome.
    private var attempted: Set<UUID> = []

    /// The last failure per repository, kept for the view to render.
    public private(set) var failures: [UUID: String] = [:]

    public init() {}

    /// Whether importing this repository is still worth doing at all.
    ///
    /// True for a repository never imported *and* for one whose import failed —
    /// a failure is a reason to try again, not a reason to stop. Use this for a
    /// deliberate gesture (the Refresh button); use ``shouldAutoImport(repoID:)``
    /// for anything unattended.
    public func shouldImport(repoID: UUID) -> Bool {
        !succeeded.contains(repoID)
    }

    /// Whether the *unattended* path may import this repository.
    ///
    /// False once any attempt has been made, so criterion 4 — "selecting the
    /// same repository repeatedly while `gh` is down must not spawn an unbounded
    /// series of `gh` calls" — is held by this type rather than by an assumption
    /// about when SwiftUI re-runs `.task(id:)`. The spec flagged that assumption
    /// as unverified; this makes it not need verifying.
    public func shouldAutoImport(repoID: UUID) -> Bool {
        !succeeded.contains(repoID) && !attempted.contains(repoID)
    }

    /// Why this repository has no cards, when the answer is not "it has none".
    public func failure(repoID: UUID) -> String? {
        failures[repoID]
    }

    public mutating func recordSuccess(repoID: UUID) {
        succeeded.insert(repoID)
        attempted.insert(repoID)
        failures[repoID] = nil
    }

    public mutating func recordFailure(repoID: UUID, message: String) {
        attempted.insert(repoID)
        succeeded.remove(repoID)
        failures[repoID] = message
    }

    /// Undo everything known about a repository, so both paths may try again.
    ///
    /// `clearDismissals` needs this: it deletes the record that suppressed
    /// cards, and a repository whose unattended attempt stayed spent would not
    /// bring them back until the user pressed Refresh.
    public mutating func forget(repoID: UUID) {
        succeeded.remove(repoID)
        attempted.remove(repoID)
        failures[repoID] = nil
    }
}
