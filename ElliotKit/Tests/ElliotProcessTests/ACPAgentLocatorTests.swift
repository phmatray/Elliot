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
    ///
    /// Parameterised by the `node` stub's script **body** rather than by a version string, so a
    /// test can drive a `node` whose `--version` cannot be read at all as easily as one that
    /// answers — which is the whole difference between "too old" and "unreadable".
    private func scratchToolchain(nodeBody: String) throws -> (
        env: LoginShellEnvironment, directory: String, remove: () -> Void
    ) {
        let dir = "/private/tmp/acp-locator-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try stub("node", body: nodeBody, at: dir)
        try stub("npx", body: "echo \"10.9.0\"", at: dir)
        let env = LoginShellEnvironment(variables: ["PATH": dir], capturedVia: "test")
        return (env, dir, { try? FileManager.default.removeItem(atPath: dir) })
    }

    private func scratchToolchain(nodeVersion: String = "v26.7.0") throws -> (
        env: LoginShellEnvironment, directory: String, remove: () -> Void
    ) {
        try scratchToolchain(nodeBody: "echo \"\(nodeVersion)\"")
    }

    /// A `#!/bin/sh` script — enough for `ToolLocator.locate`'s version probe to have something,
    /// or deliberately nothing, to read without ever touching a real `node`/`npx` binary.
    private func stub(_ name: String, body: String, at directory: String) throws {
        let path = (directory as NSString).appendingPathComponent(name)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    /// ⛔ A version Elliot could not read is not a version Elliot read and disliked.
    ///
    /// `ToolLocator.locate` leaves `LocatedTool.version` nil whenever the `--version` probe
    /// fails at all (`ProcessRunner.succeeded` is `exitCode == 0 && !timedOut`). Measured before
    /// this case existed: an executable `node` that exits 1 on `--version` resolved `.found(…
    /// version: nil …)` and was then refused as `nodeTooOld(found: "unknown")` — so an operator
    /// running Node 26 would have been told their Node is older than 22, a claim about their
    /// toolchain Elliot never established.
    @Test("a node whose --version cannot be read is not reported as too old")
    func unreadableNodeVersionIsNotTooOld() async throws {
        let (env, directory, remove) = try scratchToolchain(nodeBody: "exit 1")
        defer { remove() }
        let locator = ACPAgentLocator(environment: env)

        // The premise: the probe really did fail, so `version` is nil rather than wrong.
        #expect(await locator.resolveNode().tool?.version == nil)

        do {
            _ = try await locator.agentProcess(cwd: "/tmp", environment: [:])
            Issue.record("expected an unreadable node --version to be refused")
        } catch let error as ACPAgentLocator.LocatorError {
            guard case .nodeVersionUnreadable(let path, let reported) = error else {
                Issue.record("expected .nodeVersionUnreadable, got \(error)")
                return
            }
            #expect(path == (directory as NSString).appendingPathComponent("node"))
            #expect(reported == nil)
        }
    }

    /// The same three-valued answer from the other side: `--version` succeeded, and what it said
    /// is not a version. Elliot quotes it back instead of ranking it against the floor.
    @Test("a node --version that is not a version is quoted back, not called too old")
    func unparsableNodeVersionIsNotTooOld() async throws {
        let (env, directory, remove) = try scratchToolchain(nodeBody: "echo \"nightly-build\"")
        defer { remove() }
        let locator = ACPAgentLocator(environment: env)

        do {
            _ = try await locator.agentProcess(cwd: "/tmp", environment: [:])
            Issue.record("expected an unparsable node --version to be refused")
        } catch let error as ACPAgentLocator.LocatorError {
            guard case .nodeVersionUnreadable(let path, let reported) = error else {
                Issue.record("expected .nodeVersionUnreadable, got \(error)")
                return
            }
            #expect(path == (directory as NSString).appendingPathComponent("node"))
            #expect(reported == "nightly-build")
        }
    }

    /// ⛔ The refusal has to survive as far as the error, not just as far as the resolution.
    /// `ToolResolution` keeps `.overrideUnusable` and `.notFound` apart because "put the tool on
    /// your PATH" and "fix the variable you set" are different next actions
    /// (`ToolLocator.swift:16-19`); an error that collapses them sends someone who mistyped a
    /// path off to install software they already have.
    @Test("an unusable node override names the variable, not a missing install")
    func unusableNodeOverrideNamesTheVariable() async throws {
        let (env, _, remove) = try scratchToolchain()
        defer { remove() }
        let overrides = ToolOverrides(["node": "/tmp/definitely-not-here-9f3a"])
        let locator = ACPAgentLocator(environment: env, overrides: overrides)

        let resolution = await locator.resolveNode()
        #expect(
            resolution == .overrideUnusable(
                variable: "ELLIOT_NODE_PATH", value: "/tmp/definitely-not-here-9f3a"))

        do {
            _ = try await locator.agentProcess(cwd: "/tmp", environment: [:])
            Issue.record("expected an unusable node override to be refused")
        } catch let error as ACPAgentLocator.LocatorError {
            guard case .nodeOverrideUnusable(let variable, let value) = error else {
                Issue.record("expected .nodeOverrideUnusable, got \(error)")
                return
            }
            #expect(variable == "ELLIOT_NODE_PATH")
            #expect(value == "/tmp/definitely-not-here-9f3a")
        }
    }

    @Test("the argv reaches the adapter through npx, with the package pinned by name")
    func argvNamesTheAdapter() async throws {
        let (env, _, remove) = try scratchToolchain()
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
        let (env, _, remove) = try scratchToolchain(nodeVersion: "v20.11.1")
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
        let (env, _, remove) = try scratchToolchain()
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
            // ⛔ Not `.npxMissing`: npx is not missing, the variable naming it is wrong, and the
            // error is what Task 15 writes onto a card — where "install npx" would be advice to
            // install software the operator already has.
            guard case .npxOverrideUnusable(let variable, let value) = error else {
                Issue.record("expected .npxOverrideUnusable, got \(error)")
                return
            }
            #expect(variable == "ELLIOT_NPX_PATH")
            #expect(value == "/tmp/definitely-not-here-9f3a")
        }
    }
}
