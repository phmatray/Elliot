import Foundation

/// Where a repository belongs on disk.
///
/// The portfolio is laid out `<root>/<owner>/<public|private>/<name>`. Anything
/// that does not match that exactly — a sibling root like `_worktrees/`, a
/// nested directory, an owner we do not manage — is **out of scope**, not
/// misplaced: `slot(forPath:)` answers `nil` rather than guessing, because the
/// caller's next move would be to offer to move the directory.
public struct RepoTreeLayout: Codable, Sendable, Hashable {
    public var root: String
    public var owners: [String]

    public init(root: String, owners: [String]) {
        self.root = Self.normalise(root)
        self.owners = owners
    }

    /// The default this machine is laid out for.
    public static var portfolio: RepoTreeLayout {
        RepoTreeLayout(
            root: NSHomeDirectory() + "/Repositories",
            owners: ["phmatray", "Atypical-Consulting"])
    }

    public func ownerDirectories() -> [String] {
        owners.flatMap { owner in RepoVisibility.allCases.map { "\(root)/\(owner)/\($0.rawValue)" } }
    }

    public func expectedPath(nameWithOwner: String, visibility: RepoVisibility) -> String? {
        let parts = nameWithOwner.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty, owners.contains(String(parts[0])) else { return nil }
        return "\(root)/\(parts[0])/\(visibility.rawValue)/\(parts[1])"
    }

    public func slot(forPath path: String) -> RepoSlot? {
        let normalised = Self.normalise(path)
        guard normalised.hasPrefix(root + "/") else { return nil }
        let parts = normalised.dropFirst(root.count + 1).split(separator: "/")
        guard parts.count == 3,
            owners.contains(String(parts[0])),
            let visibility = RepoVisibility(rawValue: String(parts[1]))
        else { return nil }
        return RepoSlot(owner: String(parts[0]), visibility: visibility, name: String(parts[2]))
    }

    private static func normalise(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }
}

public enum RepoVisibility: String, Codable, Sendable, Hashable, CaseIterable {
    case `public`
    case `private`

    /// `gh repo list --json visibility` answers PUBLIC / PRIVATE / INTERNAL.
    /// Anything not public is filed as private: the folder is about who can read
    /// the clone, and internal is not public.
    public init(ghVisibility: String) {
        self = ghVisibility.uppercased() == "PUBLIC" ? .public : .private
    }
}

public struct RepoSlot: Sendable, Hashable, Codable {
    public var owner: String
    public var visibility: RepoVisibility
    public var name: String

    public init(owner: String, visibility: RepoVisibility, name: String) {
        self.owner = owner
        self.visibility = visibility
        self.name = name
    }

    public var nameWithOwner: String { "\(owner)/\(name)" }
}
