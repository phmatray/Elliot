import ElliotModel
import Foundation
import Testing

@testable import ElliotProcess

/// The disk-touching half of a method's project requirements.
///
/// `MethodPack.projectGaps` decides without reading anything; this reads without
/// deciding anything. The split is the one `nextCandidates` / `rankNextSteps`
/// already practise, and it is what makes the deciding half testable with no
/// filesystem at all.
///
/// Real temporary directories rather than a fake `FileManager`: what is asserted
/// here is what the filesystem answered, including the `/tmp` → `/private/tmp`
/// symlink that cost this repository a bug in #167.
@Suite("Artifact probe")
struct ArtifactProbeTests {

    /// A checkout under `/private/tmp`, addressable by both spellings.
    ///
    /// Deliberately **not** `FileManager.default.temporaryDirectory`: that hands
    /// back `/var/folders/…`, whose symlink hop is real but is not the one the
    /// project's own verification recipe walks into. `/tmp/elliot-check` is the
    /// scratch home CLAUDE.md tells everyone to use.
    private func checkout() throws -> (short: String, long: String, remove: () -> Void) {
        let name = "elliot-probe-\(UUID().uuidString)"
        let long = "/private/tmp/\(name)"
        try FileManager.default.createDirectory(atPath: long, withIntermediateDirectories: true)
        return ("/tmp/\(name)", long, { try? FileManager.default.removeItem(atPath: long) })
    }

    private func write(_ relative: String, under root: String) throws {
        let url = URL(fileURLWithPath: root).appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    // MARK: - What it answers

    @Test("A file that is there is true, and one that is not is false")
    func filePresence() throws {
        let (short, long, remove) = try checkout()
        defer { remove() }
        try write(".planning/PROJECT.md", under: long)

        let answer = try ArtifactProbe(repoRoot: short)
            .evaluate([.file(".planning/PROJECT.md"), .file("docs/prd.md")])

        #expect(answer[.file(".planning/PROJECT.md")] == true)
        // Present and `false`, never absent. `projectGaps` counts a missing key
        // as unsatisfied, so a probe that omitted the answer would produce the
        // right gap for the wrong reason — and would go on producing it after
        // the file appeared.
        #expect(answer[.file("docs/prd.md")] == false)
        #expect(answer.count == 2)
    }

    /// ⛔ Measured: `FileManager.fileExists(atPath:)` answers `true` for a
    /// directory. Without the `isDirectory` check, `.file("specs")` reads as
    /// satisfied by an empty `specs/` — the exact state the sibling test below
    /// exists to refuse, passing under a different case name.
    @Test("A directory does not satisfy .file")
    func fileEvidenceIsNotSatisfiedByADirectory() throws {
        let (short, long, remove) = try checkout()
        defer { remove() }
        try FileManager.default.createDirectory(
            atPath: long + "/docs", withIntermediateDirectories: true)

        let answer = try ArtifactProbe(repoRoot: short).evaluate([.file("docs")])
        #expect(answer[.file("docs")] == false)
    }

    @Test("anyFileUnder is about files, not about the directory existing")
    func anyFileUnderNeedsAFile() throws {
        let (short, long, remove) = try checkout()
        defer { remove() }
        // An empty directory is exactly the state a half-run method leaves, and
        // it must not read as satisfied.
        try FileManager.default.createDirectory(
            atPath: long + "/specs", withIntermediateDirectories: true)

        let probe = ArtifactProbe(repoRoot: short)
        #expect(try probe.evaluate([.anyFileUnder("specs")])[.anyFileUnder("specs")] == false)
        #expect(try probe.evaluate([.anyFileUnder("nope")])[.anyFileUnder("nope")] == false)

        // At any depth, and hidden files count: `.specify/` and `.planning/` are
        // the shapes these methods actually write, and a walk that skipped
        // hidden entries would report an empty tree for a method that had run.
        try write("specs/003-chat/.spec.md", under: long)
        #expect(try probe.evaluate([.anyFileUnder("specs")])[.anyFileUnder("specs")] == true)
    }

    @Test("The same evidence asked twice is answered once")
    func duplicatesCollapse() throws {
        let (short, long, remove) = try checkout()
        defer { remove() }
        try write("docs/prd.md", under: long)

        let answer = try ArtifactProbe(repoRoot: short)
            .evaluate([.file("docs/prd.md"), .file("docs/prd.md")])
        #expect(answer.count == 1)
        #expect(answer[.file("docs/prd.md")] == true)
    }

    // MARK: - What it refuses

    @Test("A path leaving the checkout is refused, and the refusal names the canonical root")
    func escapesAreRefusedAtTheCanonicalRoot() throws {
        let (short, long, remove) = try checkout()
        defer { remove() }

        do {
            _ = try ArtifactProbe(repoRoot: long).evaluate([.file("../escape.md")])
            Issue.record("a path leaving the checkout must be refused")
        } catch let error as ArtifactProbeError {
            guard case .escapesRepository(let root, let path) = error else {
                Issue.record("expected an escape refusal, got \(error)")
                return
            }
            #expect(path == "../escape.md")
            // ⛔ The canonicalisation, made observable — and in the direction it
            // actually goes. `resolvingSymlinksInPath()` **strips** `/private`
            // for an existing path, so a caller who spelled the root
            // `/private/tmp/…` is reported the `/tmp/…` spelling. Asserting the
            // reverse is what an earlier draft did, and it fails on this machine.
            #expect(root == short)
            #expect(root != long)
        }
    }

    @Test("An absolute path is refused rather than read")
    func absolutePathsAreRefused() throws {
        let (short, _, remove) = try checkout()
        defer { remove() }

        // The **case**, not merely `ArtifactProbeError.self`. Four cases carry
        // four different sentences and one of them names the repository root;
        // a probe that answered `.malformed` here would tell a reader their
        // evidence was misspelt when what it did was reach outside the
        // checkout — and the loose assertion could not tell the two apart.
        #expect {
            _ = try ArtifactProbe(repoRoot: short).evaluate([.file("/etc/hosts")])
        } throws: { error in
            guard case ArtifactProbeError.escapesRepository = error else { return false }
            return true
        }
    }

    @Test("Evidence naming nothing inside the checkout is malformed, not satisfied")
    func emptyPathIsMalformed() throws {
        let (short, _, remove) = try checkout()
        defer { remove() }

        // `.file("")` would otherwise test the checkout directory itself and
        // answer `true` — a requirement reported satisfied by a path that names
        // no artefact at all.
        #expect {
            _ = try ArtifactProbe(repoRoot: short).evaluate([.file("")])
        } throws: { error in
            guard case ArtifactProbeError.malformed = error else { return false }
            return true
        }
    }

    @Test("A checkout it cannot read throws — it never answers with an empty map")
    func unreadableThrows() {
        // ⛔ The whole reason `evaluate` throws. An empty map reads as "every
        // requirement is missing", which would put N false gaps on a screen for
        // a directory nobody could open — the same lie `ArtifactSweeper`'s
        // "no protected set, no sweep" rule exists to prevent, one layer over.
        let absent = "/private/tmp/elliot-probe-absent-\(UUID().uuidString)"
        do {
            let answer = try ArtifactProbe(repoRoot: absent)
                .evaluate([.file("docs/prd.md"), .anyFileUnder("specs")])
            Issue.record("expected a refusal, got \(answer.count) answers")
        } catch let error as ArtifactProbeError {
            guard case .unreadable(let root, let reason) = error else {
                Issue.record("expected an unreadable refusal, got \(error)")
                return
            }
            // ⚠️ The other half of the asymmetry: `resolvingSymlinksInPath()`
            // only strips `/private` for a path that exists, so an absent root
            // is reported exactly as the caller spelled it.
            #expect(root == absent)
            #expect(!reason.isEmpty)
            // The sentence Preflight puts on screen has to name a cause.
            #expect(error.localizedDescription.contains("could not be read"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    /// ⛔ The refusal the doc comment claims and an earlier draft did not
    /// implement. Measured: on a `chmod 000` directory the enumerator is
    /// **non-nil** and yields **zero** entries, so a walk alone answers `false`
    /// — "there is nothing there" for a directory nobody could read, which is
    /// exactly the lie this type exists to refuse.
    @Test("A directory that cannot be listed throws rather than answering false")
    func unlistableDirectoryThrows() throws {
        // As root every directory is readable, and the check would be vacuous.
        guard getuid() != 0 else { return }
        let (short, long, remove) = try checkout()
        defer { remove() }
        try write("specs/003/spec.md", under: long)
        let locked = long + "/specs"
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: locked) }

        do {
            let answer = try ArtifactProbe(repoRoot: short).evaluate([.anyFileUnder("specs")])
            Issue.record("an unreadable directory answered \(String(describing: answer.first))")
        } catch let error as ArtifactProbeError {
            guard case .unlistable(let path) = error else {
                Issue.record("expected .unlistable, got \(error)")
                return
            }
            #expect(path.hasSuffix("/specs"))
        }
    }

    @Test("A file where a checkout was expected is a refusal, not a directory with nothing in it")
    func aFileIsNotACheckout() throws {
        let (short, long, remove) = try checkout()
        defer { remove() }
        try write("notADirectory", under: long)

        #expect {
            _ = try ArtifactProbe(repoRoot: short + "/notADirectory").evaluate([.file("a.md")])
        } throws: { error in
            guard case ArtifactProbeError.unreadable(_, let reason) = error else { return false }
            // The reason too: `evaluate`'s first three guards all throw
            // `.unreadable` and differ only in this string, so the case alone
            // would not tell "it is a file" from "there is nothing there".
            return reason == "it is a file, not a directory"
        }
    }

    /// The third of `evaluate`'s three root guards, and the one no test drove.
    ///
    /// A checkout that exists, is a directory, and cannot be read: the case a
    /// reader meets when a repository lives behind permissions their account
    /// does not hold. Without this the guard could be deleted and the suite
    /// would stay green — the probe would then fall through to the walk and
    /// report every requirement *unsatisfied*, which reads as "this project is
    /// missing its artefacts" rather than "Elliot could not look".
    ///
    /// ⚠️ Skipped for `root`, who bypasses the permission bits: the assertion
    /// would be false there, and a test that quietly means nothing under one
    /// account is worse than one that says why it stood down.
    @Test("A checkout that cannot be read is a refusal, not a project with nothing in it")
    func anUnreadableCheckoutIsARefusal() throws {
        try #require(getuid() != 0, "run as root, the permission bits do not apply")
        let (short, long, remove) = try checkout()
        defer {
            // Before `remove()`, or the directory cannot be walked to delete it.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: long)
            remove()
        }
        try write("a.md", under: long)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: long)

        #expect {
            _ = try ArtifactProbe(repoRoot: short).evaluate([.file("a.md")])
        } throws: { error in
            guard case ArtifactProbeError.unreadable(_, let reason) = error else { return false }
            return reason == "it is not readable"
        }
    }

    @Test("No evidence is no work, and no refusal")
    func emptyInput() throws {
        let (short, _, remove) = try checkout()
        defer { remove() }
        #expect(try ArtifactProbe(repoRoot: short).evaluate([]).isEmpty)
    }
}
