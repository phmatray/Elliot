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
    /// What a `node` resolution amounts to — **five answers, not two**.
    ///
    /// ⛔ This exists because two callers now need the same judgement and a second copy of it is
    /// exactly how the collapse gets reintroduced. `resolveAdapter()` turns it into a refusal;
    /// `PreflightService`'s `tool.node` row turns it into a sentence a person reads. The plan for
    /// that row prescribed only two failing renderings — *"Not found."* and *"Found X, but the
    /// adapter needs 22 or newer."* — which would have rendered a Node whose `--version` could not
    /// be read as `"Found " + nothing`, and told someone running Node 26 their Node was old.
    /// **Elliot never established that a Node it could not read is old.**
    ///
    /// `unreadable` carries the tool, so a screen can still name the binary it could not read;
    /// `reported` is nil when `--version` failed outright and quotes the answer when it succeeded
    /// and said something that is not a version. Exactly `LocatorError.nodeVersionUnreadable`'s
    /// payload, because it becomes one.
    public enum NodeVerdict: Sendable, Hashable {
        case ok(LocatedTool, major: Int)
        case tooOld(LocatedTool, found: String)
        case unreadable(LocatedTool, reported: String?)
        case overrideUnusable(variable: String, value: String)
        case missing
    }

    /// Pure, and `static`, so the whole matrix is assertable without a toolchain on disk.
    public static func nodeVerdict(_ resolution: ToolResolution) -> NodeVerdict {
        switch resolution {
        case .notFound:
            return .missing
        case .overrideUnusable(let variable, let value):
            return .overrideUnusable(variable: variable, value: value)
        case .found(let tool):
            // ⛔ "too old" is one of *three* answers, not the negation of "new enough".
            // `ToolLocator.locate` leaves `version` nil whenever the `--version` probe fails at
            // all, so collapsing that into `nodeTooOld(found: "unknown")` — which is what this
            // did until it was measured — tells someone running Node 26 that their Node is older
            // than 22.
            guard let reported = tool.version else { return .unreadable(tool, reported: nil) }
            guard let major = majorVersion(of: reported) else {
                return .unreadable(tool, reported: reported)
            }
            return major >= minimumNodeMajor ? .ok(tool, major: major) : .tooOld(tool, found: reported)
        }
    }

    public func resolveAdapter() async throws -> (executable: String, arguments: [String]) {
        // ⛔ Refuse, never fall through — a version this adapter has never been measured against
        // is not a "close enough", which is the failure shape `ToolResolution.overrideUnusable`'s
        // doc comment names. Every arm below is a throw; the classifier above is what keeps this
        // refusal and Preflight's sentence answering the same question the same way.
        switch Self.nodeVerdict(await resolveNode()) {
        case .ok:
            break
        case .tooOld(_, let found):
            throw LocatorError.nodeTooOld(found: found)
        case .unreadable(let tool, let reported):
            throw LocatorError.nodeVersionUnreadable(path: tool.path, reported: reported)
        case .overrideUnusable(let variable, let value):
            throw LocatorError.nodeOverrideUnusable(variable: variable, value: value)
        case .missing:
            throw LocatorError.nodeMissing
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
    ///
    /// ⚠️ Node's half of this used to live here as `resolvedNode()`; it is now `nodeVerdict`'s,
    /// which answers **five** ways rather than three because Preflight needs the passing case and
    /// the two unreadable ones by name. `npx` keeps the three-way shape: nothing reads its version,
    /// so there is no floor to be below and nothing to be unreadable.
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
