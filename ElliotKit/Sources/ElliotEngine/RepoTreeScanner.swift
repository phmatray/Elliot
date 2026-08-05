import ElliotModel
import Foundation

/// Lists the clones under the configured owner folders.
///
/// One level deep, on purpose. A recursive walk of ~/Repositories would find the
/// linked worktrees under `_worktrees/`, the clones under `_local-only/` and the
/// customer trees — and the reconciler would then offer to *move* each one into
/// an owner folder. Depth is the safety property here.
public struct RepoTreeScanner: Sendable {
    private let layout: RepoTreeLayout

    public init(layout: RepoTreeLayout) {
        self.layout = layout
    }

    public func scan() -> [RepoSlot] {
        let fileManager = FileManager.default
        return layout.ownerDirectories().flatMap { directory -> [RepoSlot] in
            guard let entries = try? fileManager.contentsOfDirectory(atPath: directory) else { return [] }
            return entries.compactMap { entry in
                let path = "\(directory)/\(entry)"
                guard fileManager.fileExists(atPath: path + "/.git") else { return nil }
                return layout.slot(forPath: path)
            }
        }
    }
}
