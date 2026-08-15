import Foundation

/// Finds the ACP adapter Elliot spawns, the way `ToolLocator` finds `claude`/`gh`/`git`: through
/// a captured login-shell environment, never an inherited `PATH`.
///
/// The adapter is reached through `npx`, and `npx` resolves the CLI it runs **from inside its
/// own npm dependency** (`@anthropic-ai/claude-agent-sdk`), not the `claude` `ToolLocator`
/// already finds. That skew is structural, not a simplification opportunity — see
/// `ACPAgentProcess`'s doc comment.
public struct ACPAgentLocator: Sendable {
    private let locator: ToolLocator

    public init(environment: LoginShellEnvironment, overrides: ToolOverrides = ToolOverrides()) {
        self.locator = ToolLocator(environment: environment, overrides: overrides)
    }

    /// ⛔ Version-pinned. See decision 10.
    ///
    /// `npx --yes @agentclientprotocol/claude-agent-acp` with no version resolves **latest on
    /// every spawn**, and the adapter ships roughly every 2–3 days. Every fact this design rests
    /// on — the mode values, the config options, the five committed fixtures — was measured
    /// against `0.66.0`. Unpinned, the agent version behind an unattended `bypassPermissions` run
    /// could change between two card drags with nothing on screen. Raising the pin is a separate
    /// commit that re-takes the spec's measurements against the new version.
    public static let adapterVersion = "0.66.0"

    /// The pin is part of the argv, not a comment about it (decision 10).
    public static let adapterPackage = "@agentclientprotocol/claude-agent-acp@\(adapterVersion)"

    public static let minimumNodeMajor = 22

    public func resolveNode() async -> ToolResolution {
        await locator.locate("node")
    }

    public func resolveNpx() async -> ToolResolution {
        await locator.locate("npx")
    }

    /// The argv only — what `AppModel` puts on `ToolConfig` at launch, and what Preflight
    /// spawns. Separate from `agentProcess` because the executable and its arguments are a
    /// per-machine fact while `cwd` is a per-run one.
    public func resolveAdapter() async throws -> (executable: String, arguments: [String]) {
        let node = try await resolvedNode()

        // ⛔ Refuse, never fall through — an unparsable or too-old version is a machine this
        // adapter has never been measured on, and a silent "close enough" here is exactly the
        // failure shape `ToolResolution.overrideUnusable`'s doc comment names.
        guard let major = Self.majorVersion(of: node.version), major >= Self.minimumNodeMajor else {
            throw LocatorError.nodeTooOld(found: node.version ?? "unknown")
        }

        let npx = try await resolvedNpx()
        return (npx.path, ["--yes", Self.adapterPackage])
    }

    public func agentProcess(cwd: String, environment: [String: String]) async throws -> ACPAgentProcess {
        let (executable, arguments) = try await resolveAdapter()
        return ACPAgentProcess(
            executable: executable, arguments: arguments, cwd: cwd, environment: environment)
    }

    /// ⛔ **Refuse, never fall through.** `ToolResolution.overrideUnusable` exists precisely
    /// because "I told it which binary to use and it quietly ran a different one" is this
    /// repository's most-catalogued failure shape (#238). Both arms below are a throw — an
    /// override that cannot be run is never a reason to go searching `PATH` instead.
    private func resolvedNode() async throws -> LocatedTool {
        switch await resolveNode() {
        case .found(let tool):
            return tool
        case .overrideUnusable, .notFound:
            throw LocatorError.nodeMissing
        }
    }

    private func resolvedNpx() async throws -> LocatedTool {
        switch await resolveNpx() {
        case .found(let tool):
            return tool
        case .overrideUnusable, .notFound:
            throw LocatorError.npxMissing
        }
    }

    /// Parses the major out of `node --version`'s `vXX.Y.Z`, tolerating a missing leading `v`.
    private static func majorVersion(of raw: String?) -> Int? {
        guard let raw else { return nil }
        let unprefixed = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        let digits = unprefixed.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    public enum LocatorError: Error, Sendable {
        case nodeMissing
        case npxMissing
        case nodeTooOld(found: String)
    }
}
