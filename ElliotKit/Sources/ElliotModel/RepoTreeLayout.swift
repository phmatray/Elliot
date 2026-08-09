import Foundation

/// Where a repository belongs on disk.
///
/// The portfolio is laid out `<root>/<owner>/<public|private>/<name>`. Anything
/// that does not match that exactly — a sibling root like `_worktrees/`, a
/// nested directory, an owner we do not manage — is **out of scope**, not
/// misplaced: `slot(forPath:)` answers `nil` rather than guessing, because the
/// caller's next move would be to offer to move the directory.
public struct RepoTreeLayout: Codable, Sendable, Hashable {
    /// `private(set)` for the same reason as ``owners``: it is normalised on the
    /// way in, and a plain `var` let a later `layout.root = "~/x"` put back a
    /// value the initialiser exists to prevent.
    public private(set) var root: String

    /// The owners whose folders this layout manages, in the order a reader sees
    /// them, each at most once.
    ///
    /// ⛔ **`private(set)`, and deduplicated at construction, because every
    /// reader would otherwise have to remember to do it.** `RepoRegistryService`
    /// fans out one task per element, so `["phmatray", "phmatray"]` made the
    /// same `gh repo list` call twice — and when it failed, failed twice. #183's
    /// review found what that produced downstream: the banner's `ForEach` keys
    /// on the owner, so **two rows carried one id**, which is undefined in
    /// SwiftUI, and the sentence read *"2 owners could not be listed"* — a count
    /// of **attempts** wearing the word for **owners**.
    ///
    /// That was repaired at the reader (#148). This is the same repair at the
    /// writer, which is the one place it cannot be forgotten by whatever reads
    /// `owners` next.
    public private(set) var owners: [String]

    public init(root: String, owners: [String]) {
        self.root = Self.normalise(root)
        self.owners = Self.deduplicate(owners)
    }

    /// Decoding is a **second construction path**, and it is the one that
    /// carries a legacy duplicate in from disk — a layout stored before this
    /// rule existed. Funnelled through the memberwise initialiser so a value
    /// read back is normalised exactly like one built in code, rather than
    /// throwing at a reader who did nothing wrong.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            root: try container.decode(String.self, forKey: .root),
            owners: try container.decode([String].self, forKey: .owners)
        )
    }

    /// First occurrence wins, so the banner and ``ownerDirectories()`` keep the
    /// order the reader configured.
    ///
    /// ⚠️ **Exact comparison, deliberately, and it is the same rule the three
    /// readers use** — `expectedPath(nameWithOwner:)`, `slot(forPath:)` and the
    /// Repositories view all compare exactly. A writer that merged
    /// `["phmatray", "PhMatray"]` while they went on treating those as two
    /// owners is precisely the writer/reader split this change exists to close.
    ///
    /// GitHub handles are case-insensitive, which argues the other way, and it
    /// loses to this: `owners` names **directories**. APFS can be formatted
    /// case-sensitive, so on such a volume `PhMatray/` and `phmatray/` are two
    /// directories, and a layout that had merged them would resolve paths that
    /// do not exist. Exact is correct on both kinds of volume; case-insensitive
    /// is correct on only one.
    ///
    /// The cost is stated rather than hidden: on a case-insensitive volume two
    /// spellings still fan out twice. That is a configuration the reader can see
    /// and fix in the Repositories window, not a silent merge by a type that
    /// cannot know which spelling they meant.
    private static func deduplicate(_ owners: [String]) -> [String] {
        var seen: Set<String> = []
        return owners.filter { seen.insert($0).inserted }
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
