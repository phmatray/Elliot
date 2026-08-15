import ElliotModel
import Foundation
import Testing

@testable import ElliotProcess

/// #381 stage 1, task 5: which adapter process gets spawned, and how Elliot finds it.
///
/// Every test here builds a `LoginShellEnvironment` whose only search path is a scratch
/// directory holding executable `node`/`npx` stubs, so resolution never touches this machine's
/// real toolchain and these pass or fail independently of what happens to be installed here.
@Suite("ACP agent locator")
struct ACPAgentLocatorTests {

    /// A `PATH` containing nothing but a scratch directory with stub `node`/`npx` executables.
    private func scratchToolchain(nodeVersion: String = "v26.7.0") throws -> (
        env: LoginShellEnvironment, remove: () -> Void
    ) {
        let dir = "/private/tmp/acp-locator-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try stub("node", prints: nodeVersion, at: dir)
        try stub("npx", prints: "10.9.0", at: dir)
        let env = LoginShellEnvironment(variables: ["PATH": dir], capturedVia: "test")
        return (env, { try? FileManager.default.removeItem(atPath: dir) })
    }

    /// A one-line `#!/bin/sh` script that answers `--version` (and anything else) with a fixed
    /// string — enough for `ToolLocator.locate`'s version probe to have something to read
    /// without ever touching a real `node`/`npx` binary.
    private func stub(_ name: String, prints version: String, at directory: String) throws {
        let path = (directory as NSString).appendingPathComponent(name)
        let script = "#!/bin/sh\necho \"\(version)\"\n"
        try Data(script.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    @Test("the argv reaches the adapter through npx, with the package pinned by name")
    func argvNamesTheAdapter() async throws {
        let (env, remove) = try scratchToolchain()
        defer { remove() }
        let locator = ACPAgentLocator(environment: env)

        let agent = try await locator.agentProcess(cwd: "/tmp", environment: [:])

        #expect(agent.executable.hasSuffix("/npx"))
        #expect(agent.arguments == ["--yes", ACPAgentLocator.adapterPackage])
        // The pin is part of the argv, not a comment about it (decision 10).
        #expect(ACPAgentLocator.adapterPackage.hasSuffix("@\(ACPAgentLocator.adapterVersion)"))
        #expect(agent.cwd == "/tmp")
    }

    @Test("a Node older than 22 is refused by name, not silently used")
    func oldNodeIsRefused() async throws {
        let (env, remove) = try scratchToolchain(nodeVersion: "v20.11.1")
        defer { remove() }
        let locator = ACPAgentLocator(environment: env)

        do {
            _ = try await locator.agentProcess(cwd: "/tmp", environment: [:])
            Issue.record("expected a Node 20 toolchain to be refused")
        } catch let error as ACPAgentLocator.LocatorError {
            guard case .nodeTooOld(let found) = error else {
                Issue.record("expected .nodeTooOld, got \(error)")
                return
            }
            #expect(found == "v20.11.1")
        }
    }

    /// ⛔ NOT "a scratch PATH without npx". `ToolLocator.find` (`ToolLocator.swift:144-171`)
    /// searches, in order: the override, `environment.searchPaths`, then hardcoded candidates
    /// `/opt/homebrew/bin/<tool>`, `/usr/local/bin/<tool>`, `/usr/bin/<tool>`, then
    /// `/bin/zsh -lic "command -v <tool>"`. A scratch environment holding only `node` therefore
    /// does **not** make npx unresolvable on any machine that has npx — which is this one and
    /// the `macos-26` runner. Drive the case that is decidable offline instead: `ELLIOT_NPX_PATH`
    /// pointing at a path that is not an executable file, which `locate` answers with
    /// `.overrideUnusable` before it searches anything.
    @Test("an npx that cannot be run is refused by name, never fallen back from")
    func unusableNpxIsRefused() async throws {
        let (env, remove) = try scratchToolchain()
        defer { remove() }
        let overrides = ToolOverrides(["npx": "/tmp/definitely-not-here-9f3a"])
        let locator = ACPAgentLocator(environment: env, overrides: overrides)

        let resolution = await locator.resolveNpx()
        #expect(
            resolution == .overrideUnusable(
                variable: "ELLIOT_NPX_PATH", value: "/tmp/definitely-not-here-9f3a"))

        do {
            _ = try await locator.agentProcess(cwd: "/tmp", environment: [:])
            Issue.record("expected an unusable npx override to be refused")
        } catch let error as ACPAgentLocator.LocatorError {
            guard case .npxMissing = error else {
                Issue.record("expected .npxMissing, got \(error)")
                return
            }
        }
    }
}
