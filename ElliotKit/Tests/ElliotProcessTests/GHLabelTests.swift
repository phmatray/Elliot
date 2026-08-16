import ElliotModel
import Foundation
import TestSupport
import Testing

@testable import ElliotProcess

/// Reading and creating a repository's labels, driven through `Scripts/fake-gh.sh`.
///
/// The same seam every other `gh` test uses: `GHClient` spawns
/// `ToolConfig.ghPath`, so pointing it at the script keeps the real subprocess
/// and the real decode under test with no network and no `gh` on the machine.
@Suite("GitHub labels")
struct GHLabelTests {
    private enum Paths {
        static let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ElliotProcessTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ElliotKit
            .deletingLastPathComponent()   // repo root

        static let fakeGH = repoRoot.appendingPathComponent("Scripts/fake-gh.sh").path
        static func fixture(_ name: String) -> String {
            repoRoot.appendingPathComponent("Fixtures/gh/\(name)").path
        }
    }

    private func client(_ environment: [String: String] = [:]) -> GHClient {
        GHClient(config: ToolConfig(
            ghPath: Paths.fakeGH,
            gitPath: "/usr/bin/false",
            environment: environment
        ))
    }

    private func argvFile() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("gh-labels-argv-\(UUID().uuidString)").path
    }

    @Test("A repository's labels come back as names")
    func labelsDecode() async throws {
        let names = try await client(["FAKE_GH_LABELS": Paths.fixture("labels.json")])
            .labels(repo: "phmatray/Elliot")

        #expect(names.contains("bug"))
        #expect(names.contains("enhancement"))
        #expect(names.count >= 2)
    }

    @Test("A gh that fails throws, rather than answering an empty list")
    func failureThrows() async {
        // The distinction the whole check rests on. `[]` is a *finding* — "this
        // repository has no labels" — and returning it for a failed call would
        // report every label as missing on a repository nobody could reach, then
        // offer a button to create them.
        await #expect(throws: (any Error).self) {
            try await client([
                "FAKE_GH_MODE": "fail",
                "FAKE_GH_LABELS": Paths.fixture("labels.json"),
            ]).labels(repo: "phmatray/Elliot")
        }
    }

    @Test("A repository with no labels is an empty list, not a failure")
    func emptyIsNotAnError() async throws {
        // No fixture configured: the fake prints `[]`, which is what real `gh`
        // returns for a repository with none. That must decode, not throw.
        let names = try await client().labels(repo: "phmatray/Elliot")
        #expect(names.isEmpty)
    }

    @Test("Creating a label passes its name, colour and description to gh")
    func createPassesEveryField() async throws {
        let argv = argvFile()
        defer { try? FileManager.default.removeItem(atPath: argv) }

        try await client(["FAKE_GH_ARGV_OUT": argv]).createLabel(
            RequiredLabel(name: "bug", color: "d73a4a", description: "Something isn't working"),
            repo: "phmatray/Elliot"
        )

        let arguments = try String(contentsOfFile: argv, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(arguments.prefix(2) == ["label", "create"])
        #expect(arguments.contains("bug"))
        // Asserted as a pair, not just as present: a colour that landed under
        // `--description` would still "contain" both strings.
        #expect(arguments.contains("--color"))
        // Not `arguments[(firstIndex(of:) ?? 0) + 1]`: with the flag absent that
        // read index 1 and could compare equal to a value that was never after
        // `--color` at all — a trap's quieter cousin. This fails by name.
        #expect(argumentValues(after: "--color", in: arguments) == ["d73a4a"])
        #expect(arguments.contains("--description"))
        #expect(
            argumentValues(after: "--description", in: arguments) == ["Something isn't working"])
        #expect(arguments.contains("--repo"))
    }

    @Test("A label that already exists is success, not an error")
    func alreadyExistsIsSuccess() async throws {
        // `gh label create` exits non-zero on a name that is already taken. Two
        // Elliot windows, or a label created by hand between the check and the
        // button, must not turn a no-op into a red banner — the end state the
        // caller wanted is the end state they have.
        try await client([
            "FAKE_GH_MODE": "fail",
            "FAKE_GH_STDERR": "already exists",
        ]).createLabel(
            RequiredLabel(name: "bug", color: "d73a4a", description: "Something isn't working"),
            repo: "phmatray/Elliot"
        )
    }

    @Test("A create that fails for any other reason still throws")
    func otherFailuresThrow() async {
        // The already-exists tolerance must be narrow. A create refused for
        // permissions, or a repository that does not exist, has to reach the
        // caller — swallowing it would report labels as created that are not.
        await #expect(throws: (any Error).self) {
            try await client([
                "FAKE_GH_MODE": "fail",
                "FAKE_GH_STDERR": "HTTP 403: Resource not accessible by integration",
            ]).createLabel(
                RequiredLabel(name: "bug", color: "d73a4a", description: "x"),
                repo: "phmatray/Elliot"
            )
        }
    }
}
