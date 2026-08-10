import Foundation

/// A registered git repository the board can drive.
///
/// `path` must be the **main checkout**, never a linked worktree: `merge-pr`
/// tears down the PR's worktree and cannot do that from inside it.
public struct Repo: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var path: String
    /// `owner/name`, resolved once via `gh repo view --json nameWithOwner`.
    /// Every verifier passes it as `--repo` rather than relying on cwd.
    public var nameWithOwner: String
    public var defaultBranch: String
    public var displayName: String

    /// Passed to `claude --permission-mode`. Per-repo so a single repo can be
    /// tightened without touching the others.
    public var permissionMode: PermissionMode
    public var extraAllowedTools: [String]
    public var isEnabled: Bool

    /// GitHub's visibility, kept so the expected path is recomputable offline.
    public var visibility: RepoVisibility?

    /// What Preflight last said about this checkout.
    ///
    /// Stored on the registration rather than held in memory because the rule
    /// that needs it runs in `BoardService.proposeMove`, which already loads
    /// this row — so the verdict arrives with no new collaborator and no second
    /// source of truth. `AppModel` held it in `repoChecks` and no rule could
    /// reach it, which is exactly how the gate came to be asserted in three
    /// documents and implemented in none.
    ///
    /// It is a *measurement* living on a *registration*, so it can go stale. The
    /// bound is that the sweep rewrites it — at startup, on "Check again", and
    /// after a fix is applied — so a repaired repository clears at the next
    /// sweep rather than staying frozen. `notChecked` is what a row migrated
    /// from before this column holds, and it does not block.
    ///
    /// ⚠️ **Optional, and it has to be.** `BoardStore.openReadOnly` deliberately
    /// accepts a database *older* than the helper (`applied.isSubset(of: known)`)
    /// so the board is not blanked between upgrading the bundle and the next
    /// launch of the app — and that tolerance is precisely "an added column
    /// reads as absent", which only holds for an optional. Declared
    /// non-optional, this threw `GRDB.RowDecodingError` and made the helper
    /// refuse **every card** on a pre-v9 database. `OlderDatabaseTests` caught
    /// it, which is the second time that suite has caught this exact class of
    /// regression; #174 was the first.
    ///
    /// Read it through ``preflightVerdict``, never directly — `nil` is a state,
    /// not a missing value, and it means the same thing as `.notChecked`.
    public var preflight: PreflightState?

    /// The labels *this* repository requires, or `nil` if nobody has chosen.
    ///
    /// ⚠️ **`nil` and `[]` are different answers and the difference is the whole
    /// point** (#199, #200). `nil` means the taxonomy question has never been
    /// put to this repository, so `LabelPolicy.default` — Elliot's floor —
    /// applies and Preflight still offers to have the conversation. `[]` means
    /// this repository was asked and chose to require nothing, which is a
    /// decision and must not be nagged again.
    ///
    /// Elliot drives *other people's* repositories and their taxonomies are not
    /// Elliot's. The floor shipped in #172 deliberately set to GitHub's four
    /// stock labels so the mechanism could land without an argument about
    /// taxonomy; this is that argument's answer, per repository.
    ///
    /// ⛔ **Optional, and it has to be** — the same reason ``preflight`` is.
    /// `BoardStore.openReadOnly` accepts a database older than the code reading
    /// it, and that tolerance is exactly "an added column reads as absent",
    /// which only holds for an optional. Declared non-optional this throws
    /// `GRDB.RowDecodingError` and the helper refuses every repository.
    ///
    /// Read it through ``LabelPolicy/resolved(for:)``, never directly: that is
    /// the one place `nil` becomes the floor, and it returns *whose* policy it
    /// gave you along with it.
    public var labelPolicy: [RequiredLabel]?

    /// What the rule engine reads: the verdict, with "this row predates the
    /// column" folded into "nobody has swept it".
    ///
    /// One computed property rather than `?? .notChecked` at each of the four
    /// call sites. The whole defect being fixed here is a verdict that was
    /// spelled out in several places and reachable from none of the ones that
    /// mattered; four hand-written coalescings would be that shape returning.
    public var preflightVerdict: PreflightState { preflight ?? .notChecked }

    public init(
        id: UUID = UUID(),
        path: String,
        nameWithOwner: String,
        defaultBranch: String = "main",
        displayName: String,
        permissionMode: PermissionMode = .bypassPermissions,
        extraAllowedTools: [String] = [],
        isEnabled: Bool = true,
        visibility: RepoVisibility? = nil,
        preflight: PreflightState? = nil,
        labelPolicy: [RequiredLabel]? = nil
    ) {
        self.labelPolicy = labelPolicy
        self.id = id
        self.path = path
        self.nameWithOwner = nameWithOwner
        self.defaultBranch = defaultBranch
        self.displayName = displayName
        self.permissionMode = permissionMode
        self.extraAllowedTools = extraAllowedTools
        self.isEnabled = isEnabled
        self.visibility = visibility
        self.preflight = preflight
    }
}

/// Mirrors `claude --permission-mode`'s accepted values.
///
/// `manual` is the CLI's alias for the internal `default`; we store the alias
/// the CLI advertises in `--help`.
public enum PermissionMode: String, Codable, CaseIterable, Sendable, Hashable {
    case manual
    case acceptEdits
    case auto
    case dontAsk
    case plan
    case bypassPermissions
}
