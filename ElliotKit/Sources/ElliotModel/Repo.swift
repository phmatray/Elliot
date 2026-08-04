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

    public init(
        id: UUID = UUID(),
        path: String,
        nameWithOwner: String,
        defaultBranch: String = "main",
        displayName: String,
        permissionMode: PermissionMode = .bypassPermissions,
        extraAllowedTools: [String] = [],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.path = path
        self.nameWithOwner = nameWithOwner
        self.defaultBranch = defaultBranch
        self.displayName = displayName
        self.permissionMode = permissionMode
        self.extraAllowedTools = extraAllowedTools
        self.isEnabled = isEnabled
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
