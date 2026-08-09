import Foundation

/// One `git/trees?recursive=1` answer, keeping the flag the shell pipeline drops.
///
/// `paths` is **private**. Every access is three-valued, because "not in the
/// list" means nothing when the list is incomplete, and the two axes that
/// enumerate rather than look up are exactly the ones a truncation would turn
/// into a false violation.
public struct RepoTree: Codable, Sendable, Hashable {
    private var storage: Set<String>
    /// GitHub's own `truncated`.
    public var isTruncated: Bool

    /// Spelled out, because the synthesised keys would name the *storage* rather
    /// than the thing stored. A later plan persists measurements as JSON, so
    /// `storage` would become a key in a stored format and a rename of the
    /// property — the obvious tidy-up once the public vocabulary is `paths` —
    /// would silently stop decoding everything already written. Named now, while
    /// there is nothing on disk to migrate.
    private enum CodingKeys: String, CodingKey {
        case storage = "paths"
        case isTruncated = "truncated"
    }

    public init(paths: Set<String>, truncated: Bool) {
        self.storage = paths
        self.isTruncated = truncated
    }

    /// Present, absent, or unknowable.
    public func contains(_ path: String) -> Bool? {
        if storage.contains(path) { return true }
        return isTruncated ? nil : false
    }

    /// Every path under a prefix, or `nil` when the tree was truncated — an
    /// enumeration over an incomplete list is not a set.
    public func paths(withPrefix prefix: String) -> Set<String>? {
        guard !isTruncated else { return nil }
        return storage.filter { $0.hasPrefix(prefix) }
    }
}

/// Everything the collector gathered for one repository, each part carrying its
/// own age — the tree, the workflows and the topics are separate calls, and one
/// can fail while the others succeed.
public struct RepoMeasurement: Sendable, Hashable {
    public var tree: Reading<RepoTree>
    /// Workflow path → its YAML text.
    public var workflows: Reading<[String: String]>
    /// The dependency-automation config found, and its path. `nil` value means
    /// read successfully and absent — distinct from unavailable.
    public var dependencyConfig: Reading<String?>
    public var topics: Reading<[String]>
    /// SPDX id, read from `.license.spdx_id`. ⚠️ `gh repo view --json licenseInfo`
    /// omits `spdxId`; the REST payload is the source.
    public var licenceSPDX: Reading<String?>

    public init(
        tree: Reading<RepoTree>,
        workflows: Reading<[String: String]>,
        dependencyConfig: Reading<String?>,
        topics: Reading<[String]>,
        licenceSPDX: Reading<String?>
    ) {
        self.tree = tree
        self.workflows = workflows
        self.dependencyConfig = dependencyConfig
        self.topics = topics
        self.licenceSPDX = licenceSPDX
    }
}
