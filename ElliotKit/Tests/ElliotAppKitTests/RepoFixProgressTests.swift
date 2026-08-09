import ElliotModel
import Foundation
import Testing

@testable import ElliotAppKit

/// The Repositories page says which repair it is running, and starts one at a
/// time.
///
/// `apply` awaited the fix before touching any flag, and `isReconciling` was
/// raised only inside the `refreshRepoRows()` that followed — so for the whole
/// of a `gh repo clone`, bounded at 600 seconds, the page was indistinguishable
/// from idle: every `.disabled(model.isReconciling)` button stayed live, and a
/// second press or a Move on another row could interleave with a directory
/// relocation.
@Suite("Repo fix progress")
struct RepoFixProgressTests {

    @MainActor
    @Test("A fresh model is not busy, and says nothing is running")
    func idleModelIsQuiet() {
        let model = AppModel()
        #expect(model.applyingFix == nil)
        #expect(model.applyingFixSentence == nil)
        #expect(model.isRepoWorkInFlight == false)
    }

    /// Each sentence names its subject. "Cloning…" alone, on a page of
    /// repositories, does not say which one the page is waiting on — which is
    /// the entire point of showing it.
    @Test(
        "Every running sentence names what it is acting on",
        arguments: [
            RepoFix.clone(nameWithOwner: "phmatray/Elliot", into: "/tmp/x/Elliot"),
            RepoFix.move(from: "/tmp/a/Koine", to: "/tmp/b/Koine"),
            RepoFix.register(path: "/tmp/a/Koine"),
            RepoFix.pull(path: "/tmp/a/Koine"),
        ]
    )
    func everySentenceNamesItsSubject(fix: RepoFix) {
        let sentence = fix.runningSentence
        #expect(sentence.hasSuffix("…"))
        let namesSomething =
            sentence.contains("Elliot") || sentence.contains("Koine")
        #expect(namesSomething, Comment(rawValue: "\(fix) said: \(sentence)"))
    }

    @Test("A clone names the repository and where it is going")
    func cloneNamesBothEnds() {
        let sentence = RepoFix.clone(nameWithOwner: "phmatray/Elliot", into: "/tmp/private/Elliot")
            .runningSentence
        #expect(sentence.contains("phmatray/Elliot"))
        #expect(sentence.contains("Elliot…"))
    }

    /// A move relocates a directory in the user's portfolio. Naming only the
    /// destination leaves the reader unable to tell which row is moving.
    @Test("A move names where it is coming from as well as where it is going")
    func moveNamesBothEnds() {
        let sentence = RepoFix.move(from: "/tmp/public/Koine", to: "/tmp/private/Koine")
            .runningSentence
        #expect(sentence.contains("Koine"))
        #expect(sentence.contains("into"))
    }

    /// ⛔ The wording lives beside `label` so the button that starts a fix and
    /// the header that reports it cannot drift. Every case must answer both.
    @Test("Every fix has both a label and a running sentence, and they differ")
    func labelAndSentenceBothExist() {
        let fixes: [RepoFix] = [
            .clone(nameWithOwner: "o/n", into: "/tmp/n"),
            .move(from: "/tmp/a", to: "/tmp/b"),
            .register(path: "/tmp/a"),
            .forget(repoID: UUID()),
            .pull(path: "/tmp/a"),
        ]
        for fix in fixes {
            #expect(fix.label.isEmpty == false)
            #expect(fix.runningSentence.isEmpty == false)
            #expect(fix.label != fix.runningSentence)
        }
    }
}

/// Registering a checkout has one implementation, and the app is not it.
///
/// ⚠️ A source-reading gate, deliberately: `addRepo` needs a live registry and a
/// real directory to exercise, so a behavioural test here would assert against a
/// `nil` collaborator and pass no matter what the method did. What is actually
/// at stake is *shape* — whether this file builds a `Repo` of its own again —
/// and that is what this reads. The behaviour is pinned in
/// `RegistrationIsOneActTests`, against the real service.
@Suite("Registration is not written twice")
struct RegistrationShapeTests {

    private static var appModelSource: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/ElliotAppKit/AppModel.swift")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    /// The body of `addRepo`, which is the only place the old second
    /// implementation lived.
    ///
    /// ⚠️ Scoped to the body rather than searched over the file, and that is
    /// this test's own scar: the first version looked for `"Repo(path:"` across
    /// `AppModel.swift` and matched **its own subject's declaration** —
    /// `addRepo(path:` ends in exactly those characters. A string gate over
    /// source cannot tell a constructor from a substring of an identifier, which
    /// is the same reason this repository's `no CI` grep is a habit rather than
    /// a matcher.
    private static var addRepoBody: String {
        get throws {
            let source = try appModelSource
            guard
                let start = source.range(of: "public func addRepo(path: String) async {"),
                let end = source.range(
                    of: "\n    }\n", range: start.upperBound..<source.endIndex)
            else { return "" }
            return String(source[start.upperBound..<end.lowerBound])
        }
    }

    @Test("addRepo builds no Repo of its own")
    func addRepoConstructsNoRepo() throws {
        let body = try Self.addRepoBody
        #expect(body.isEmpty == false, "the method this suite is about was not found")
        // `= Repo(` is the assignment a second registration needs. The old
        // `addRepo` had exactly one, and the row it wrote disagreed with the
        // service's about `visibility` — which is what `expectedPath` reads to
        // decide where a clone belongs.
        #expect(body.contains("= Repo(") == false)
        #expect(body.contains("saveRepo") == false)
    }

    @Test("addRepo goes through the registry's own fix")
    func addRepoUsesTheRegistry() throws {
        #expect(try Self.addRepoBody.contains(".register(path: path)"))
    }
}
