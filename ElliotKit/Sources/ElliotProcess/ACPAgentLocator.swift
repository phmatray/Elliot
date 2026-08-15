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

        // ⛔ Refuse, never fall through — a version this adapter has never been measured against
        // is not a "close enough", which is the failure shape `ToolResolution.overrideUnusable`'s
        // doc comment names. ⛔ And refuse in the operator's own vocabulary: "too old" is one of
        // *three* answers, not the negation of "new enough". `ToolLocator.locate` leaves
        // `version` nil whenever the `--version` probe fails at all, so collapsing that into
        // `nodeTooOld(found: "unknown")` — which is what this did until it was measured — tells
        // someone running Node 26 that their Node is older than 22. Elliot never established
        // that, and a claim about a toolchain it could not read is worse than a refusal.
        guard let reported = node.version else {
            throw LocatorError.nodeVersionUnreadable(path: node.path, reported: nil)
        }
        guard let major = Self.majorVersion(of: reported) else {
            throw LocatorError.nodeVersionUnreadable(path: node.path, reported: reported)
        }
        guard major >= Self.minimumNodeMajor else {
            throw LocatorError.nodeTooOld(found: reported)
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
    ///
    /// ⛔ **And they throw different errors, because the refusal is only half of it.** The type
    /// being consumed keeps `.overrideUnusable` and `.notFound` apart for a stated reason
    /// (`ToolLocator.swift:16-19`): "put the tool on your PATH" and "fix the variable you set"
    /// are different next actions, and *"collapsing them would send someone who mistyped a path
    /// off to install software they already have"*. One arm each, so the distinction survives as
    /// far as the sentence Task 15 writes onto a card — not just as far as `resolveNode()`,
    /// which Preflight reads directly and which was already telling the truth.
    private func resolvedNode() async throws -> LocatedTool {
        switch await resolveNode() {
        case .found(let tool):
            return tool
        case .overrideUnusable(let variable, let value):
            throw LocatorError.nodeOverrideUnusable(variable: variable, value: value)
        case .notFound:
            throw LocatorError.nodeMissing
        }
    }

    private func resolvedNpx() async throws -> LocatedTool {
        switch await resolveNpx() {
        case .found(let tool):
            return tool
        case .overrideUnusable(let variable, let value):
            throw LocatorError.npxOverrideUnusable(variable: variable, value: value)
        case .notFound:
            throw LocatorError.npxMissing
        }
    }

    /// Parses the major out of `node --version`'s `vXX.Y.Z`, tolerating a missing leading `v`.
    /// Nil means "this is not a version", which is a separate answer from "below the floor" and
    /// is reported as one.
    private static func majorVersion(of raw: String) -> Int? {
        let unprefixed = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        let digits = unprefixed.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// Why the adapter could not be resolved — one case per *next action*, never per site that
    /// gave up. Tasks 16 and 15 will render these into Preflight rows and onto a failed card;
    /// neither is written yet, so what follows cites the plan where it quotes their wording.
    public enum LocatorError: Error, Sendable {
        /// No `node` on the captured `PATH`, in any known install location, or via
        /// `command -v`. Next action: install it.
        case nodeMissing

        /// `ELLIOT_NODE_PATH` names something that is not an executable file. Next action: fix
        /// the variable — the software is very likely already installed.
        case nodeOverrideUnusable(variable: String, value: String)

        case npxMissing
        case npxOverrideUnusable(variable: String, value: String)

        /// A version was read, parsed, and is below `minimumNodeMajor`.
        ///
        /// ⛔ The payload is non-optional on purpose: this case is now reachable *only* after a
        /// successful parse, so `found` is always a version Elliot actually read. It carried
        /// `node.version ?? "unknown"` until the case below existed — and the row the plan
        /// prescribes for `tool.node` is *"Found \(version), but the adapter needs 22 or newer."*
        /// (plan line 2945), which that would have filled in as *"Found unknown"*.
        case nodeTooOld(found: String)

        /// `node --version` could not be run at all (`reported` nil), or answered something that
        /// is not a version (`reported` quotes it). Either way Elliot has **no** reading of this
        /// toolchain and says so, rather than ranking a non-answer against the floor.
        ///
        /// One case rather than two: the next action is the same — look at that binary — and only
        /// what there is to show differs, which the optional expresses exactly.
        case nodeVersionUnreadable(path: String, reported: String?)
    }
}
