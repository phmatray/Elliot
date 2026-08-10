import ElliotModel
import Foundation

/// Resolves cited paths against a repository root.
///
/// Extracted from `ProposalHarvester` when a second harvester needed it. The
/// containment check below is the reason it is one function rather than two
/// copies: its failure mode is measured — a sibling directory `/repo-evil`
/// shares `/repo` as a string prefix without being underneath it — and the
/// second caller is an unattended agent choosing the citations.
///
/// In `ElliotEngine` rather than `ElliotModel` because it touches the file
/// system, and `ElliotModel` is a pure island by rule.
public enum EvidenceResolver {

    /// A missing file does not disqualify a citation — it marks it, and the
    /// window strikes it through. It is the fastest signal that something was
    /// invented rather than found, so it must survive to be shown.
    public static func resolve(_ raw: [String], repoPath: String) -> [Evidence] {
        let root = URL(fileURLWithPath: repoPath).standardizedFileURL
        return raw.compactMap { citation in
            guard let parsed = Evidence.parse(citation) else { return nil }
            let resolved = root.appendingPathComponent(parsed.path).standardizedFileURL
            // A citation must stay inside the repository: "../../etc/passwd" is
            // not evidence about this codebase. The boundary check must land on
            // a path component, not a bare string prefix — otherwise a sibling
            // directory like "/repo-evil" would be accepted for a root of
            // "/repo".
            let inside = resolved.path == root.path || resolved.path.hasPrefix(root.path + "/")
            return Evidence(
                path: parsed.path,
                line: parsed.line,
                exists: inside && FileManager.default.fileExists(atPath: resolved.path)
            )
        }
    }
}
