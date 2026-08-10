import ElliotModel
import Foundation

/// Why a probe would not answer.
///
/// Four cases, and two of them are the same point: **"I could not look" is not
/// "there is nothing there".** Preflight turns either into one warning naming
/// the cause rather than one false gap per requirement.
public enum ArtifactProbeError: Error, LocalizedError, Sendable {
    /// The evidence names a path that leads out of the checkout.
    case escapesRepository(root: String, path: String)
    /// The evidence names nothing inside the checkout — `""`, `"."`, `"./"`.
    case malformed(path: String)
    /// The checkout **root** could not be read.
    case unreadable(root: String, reason: String)
    /// A directory inside the checkout exists and could not be listed. Distinct
    /// from `.unreadable`, which is about the root: rendering a subdirectory as
    /// "the checkout could not be read" would send a reader to the wrong path.
    case unlistable(path: String)

    public var errorDescription: String? {
        switch self {
        case .escapesRepository(let root, let path):
            "\(path) leads outside \(root)"
        case .malformed(let path):
            "\"\(path)\" does not name anything inside the repository"
        case .unreadable(let root, let reason):
            "\(root) could not be read: \(reason)"
        case .unlistable(let path):
            "\(path) could not be read: it exists but could not be listed"
        }
    }
}

/// Whether a method's project artefacts are on disk. Reads, and decides nothing.
///
/// The impure half of a project requirement. `MethodPack.projectGaps` is the
/// other half and takes this map — the same split `nextCandidates` and
/// `rankNextSteps` already practise, so the rule stays testable with no
/// filesystem and the filesystem stays testable with no rule.
///
/// ⛔ **It only ever reads.** No `create`, no `write`, no `remove`. A diagnostic
/// that repaired what it measured could not be re-run to check itself.
///
/// `evaluate` is not `async`, unlike every other method in this target: the
/// siblings here spawn subprocesses and this touches `FileManager` only. There
/// is nothing to await, and an `async` that never suspends is a signature making
/// a promise about its cost that is not true.
public struct ArtifactProbe: Sendable {
    private let root: String

    public init(repoRoot: String) {
        // ⚠️ Deliberately **not** `StoreLocation.canonicalPath`, and not because
        // of layering taste. That function's contract is about a *set-membership
        // comparison between two independently-built strings* — the retention
        // sweep's protected set, #167 — and this probe compares nothing: it
        // joins root + components and hands the result to `FileManager`, which
        // follows symlinks, so both spellings of `/tmp` answer identically. The
        // resolution here exists so an **error message** names the same path the
        // rest of the machine would print. Importing `ElliotStore` into
        // `ElliotProcess` and editing a union-merged manifest to buy a sentence
        // is not a trade worth making.
        //
        // ⚠️ It resolves asymmetrically, measured: `/private/tmp/<existing>`
        // comes back as `/tmp/<existing>`, while a path that does **not** exist
        // is returned unchanged. `ArtifactProbeTests` pins both halves, because
        // one of them looks like a bug from the other's side.
        self.root = URL(fileURLWithPath: repoRoot).resolvingSymlinksInPath().path
    }

    /// One answer per distinct piece of evidence.
    ///
    /// ⛔ **Throws rather than returning an empty map.** An empty map reads as
    /// "everything is missing", which is the exact lie `ArtifactSweeper`'s
    /// "no protected set, no sweep" rule exists to prevent — here it would put a
    /// gap on screen for every requirement of a repository nobody could open,
    /// each with a button offering to file a card about it.
    public func evaluate(_ evidence: [MethodPack.Evidence]) throws -> [MethodPack.Evidence: Bool] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory) else {
            throw ArtifactProbeError.unreadable(root: root, reason: "there is nothing at this path")
        }
        guard isDirectory.boolValue else {
            throw ArtifactProbeError.unreadable(root: root, reason: "it is a file, not a directory")
        }
        guard FileManager.default.isReadableFile(atPath: root) else {
            throw ArtifactProbeError.unreadable(root: root, reason: "it is not readable")
        }

        var answer: [MethodPack.Evidence: Bool] = [:]
        // Exhaustive with no `default:`, for the reason every other switch over
        // a closed vocabulary in this project is: wave 2 adds `.githubIssue`,
        // `.githubPR` and `.merged`, and each must fail to compile here so
        // someone decides what proves it rather than inheriting `false`.
        for item in evidence {
            switch item {
            case .file(let relative):
                answer[item] = isRegularFile(at: try resolve(relative))
            case .anyFileUnder(let relative):
                answer[item] = try containsRegularFile(at: try resolve(relative))
            }
        }
        return answer
    }

    /// ⛔ A **file**, not merely something at that path.
    ///
    /// `fileExists(atPath:)` answers `true` for a directory (measured), so
    /// `.file("specs")` would read as satisfied by an empty `specs/` — the state
    /// `.anyFileUnder` exists to refuse, passing under the other case's name.
    private func isRegularFile(at path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return false
        }
        return !isDirectory.boolValue
    }

    /// The absolute path this evidence names, refused if it leaves the checkout.
    ///
    /// **Lexical, and deliberately so.** It must answer the same way for a path
    /// that exists and one that does not — a *missing* artefact is the whole
    /// point of this probe — and `standardizingPath` resolves symlinks only for
    /// paths that exist, so a resolver here would classify a present file and an
    /// absent one by different rules. `..` is popped, `.` and empty components
    /// dropped, an absolute path refused outright.
    ///
    /// ⚠️ It does **not** stop a symlink *inside* the checkout that points out of
    /// it. Following one is a read of a file the repository itself points at, and
    /// this probe only reads. The design puts the real gate on catalogue
    /// validation, where the paths come from; this is the second lock.
    private func resolve(_ relative: String) throws -> String {
        guard !relative.hasPrefix("/") else {
            throw ArtifactProbeError.escapesRepository(root: root, path: relative)
        }
        var components: [String] = []
        for raw in relative.split(separator: "/", omittingEmptySubsequences: true) {
            let component = String(raw)
            if component == "." { continue }
            if component == ".." {
                guard !components.isEmpty else {
                    throw ArtifactProbeError.escapesRepository(root: root, path: relative)
                }
                components.removeLast()
                continue
            }
            components.append(component)
        }
        guard !components.isEmpty else {
            // The checkout itself is not an artefact. Answering `true` here
            // would report a requirement satisfied by a path naming nothing.
            throw ArtifactProbeError.malformed(path: relative)
        }
        return ([root] + components).joined(separator: "/")
    }

    /// Whether any regular file lives under this directory, at any depth.
    ///
    /// Hidden entries are **kept**: `.planning/`, `.specify/` and `.claude/` are
    /// the shapes these methods actually write, and a walk that skipped them
    /// would report an empty tree for a method that had run. This is the one
    /// place it differs from `StoreLocation.inventory`, which skips them because
    /// it is looking for artefacts Elliot itself wrote.
    ///
    /// A missing directory is `false` — a finding. ⛔ **A directory that exists
    /// and cannot be read throws**, and the readability is checked *before* the
    /// walk rather than inferred from it: measured on a `chmod 000` directory,
    /// `enumerator(at:…)` returns **non-nil** and yields **zero** entries, so a
    /// walk alone answers `false` and reports "there is nothing there" about a
    /// directory nobody could open.
    ///
    /// ⚠️ **The check covers this directory, not every directory beneath it.** A
    /// deeper subdirectory that cannot be listed still contributes no files and
    /// is not distinguished from an empty one. Closing that needs the
    /// enumerator's `errorHandler`, whose escaping closure cannot capture a
    /// local under strict concurrency without a reference box — bought when
    /// something needs it, and said here rather than left to be assumed.
    private func containsRegularFile(at directory: String) throws -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return false }

        guard FileManager.default.isReadableFile(atPath: directory) else {
            throw ArtifactProbeError.unlistable(path: directory)
        }

        guard let walk = FileManager.default.enumerator(
            at: URL(fileURLWithPath: directory),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            throw ArtifactProbeError.unlistable(path: directory)
        }

        for case let url as URL in walk {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                return true
            }
        }
        return false
    }
}
