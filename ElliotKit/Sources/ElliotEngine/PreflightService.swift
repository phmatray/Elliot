import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation

public enum CheckStatus: String, Sendable, Hashable {
    case pass, warn, fail
}

/// Something Preflight can *do* about a finding, as opposed to describe.
///
/// The Repositories page has had actionable rows since #12 — `RepoFix`, executed
/// by `RepoRegistryService.apply(_:layout:)`. Preflight had only `fixHint`,
/// which is prose. Two screens answering the same question, *here is what is
/// wrong, fix it*, and only one of them could. This is the other half.
///
/// Two cases, and which one applies is decided by **what kind of work it is**:
///
/// - `createLabels` is deterministic. `gh label create` per label, nothing to
///   decide, nothing committed. It runs **no agent** — spending an unattended
///   `claude -p` (which Elliot launches at `bypassPermissions`, in a real
///   checkout) on a `for` loop would be slower, cost money, and hand a
///   general-purpose tool write access for a job with one right answer.
/// - `seedCard` is for the work that *is* a judgement: choosing a taxonomy edits
///   `.claude/skills/repo-profile.md`, a **committed** file, so it deserves an
///   issue, a pull request and a review. That is the board's pipeline, and
///   reaching the agent through a card rather than through a button here is what
///   keeps "moving a card is the act of execution" true — a second place that
///   starts an unattended agent, outside the board, would not.
public enum CheckFix: Sendable, Hashable, Identifiable {
    /// Create these labels in this repository, now.
    ///
    /// ⚠️ `nameWithOwner` is carried rather than read back off the `Repo`, and
    /// that is not tidiness. The check asks `gh` about the **live**
    /// `repoInfo(cwd:)` value while `Repo.nameWithOwner` is whatever was stored
    /// at registration — and both registration paths fall back to a bare
    /// directory name when `gh` was unavailable
    /// (`AppModel.swift`, `RepoRegistryService.swift`: `info?.nameWithOwner ?? …`).
    /// Nothing ever repairs it. So a repository registered while `gh` was down
    /// stores `Elliot`, the check correctly reports labels missing from
    /// `phmatray/Elliot`, and the button runs `gh label create … --repo Elliot`,
    /// which `gh` rejects for not being `[HOST/]OWNER/REPO`: every label failing
    /// for a finding that was right. After a rename it is worse — the write
    /// silently targets the wrong repository.
    case createLabels(repoID: UUID, nameWithOwner: String, labels: [RequiredLabel])
    /// Put a card in Backlog describing work someone should look at.
    ///
    /// `key` is this fix's identity, and `nil` means *derive it from the title*,
    /// which is what it did before methods existed. Both spellings are needed
    /// and neither is a default anyone should change:
    ///
    /// - ⛔ The labels seed passes `nil` and must keep passing it. `apply` hands
    ///   `fix.id` to `createCard(idempotencyKey:)`, so this string is already in
    ///   databases in the field; recomputing it would let a second identical
    ///   card be created for a finding that had already been seeded.
    /// - A project requirement passes `MethodPack.idempotencyKey(for:in:)`,
    ///   which is `"method:<repoID>:<packID>:req:<reqID>"` — keyed on *what it
    ///   is about* rather than on what it says, so rewording a requirement's
    ///   title does not produce a duplicate card, **and carrying the repository**,
    ///   because `card_on_idempotencyKey` is unique board-wide.
    case seedCard(repoID: UUID, title: String, story: UserStory, key: String?)

    /// Record that this repository requires exactly these labels.
    ///
    /// Writes `Repo.labelPolicy`, which until #199 had no writer at all — the
    /// shape #333 found one field over, where a column with three readers and
    /// nothing that assigned it made a documented capability fictional.
    ///
    /// The labels are carried rather than read back, so the button applies the
    /// set the reader was *shown*: a policy resolved again at press time could
    /// differ from the one the sentence above the button described.
    case adoptLabelPolicy(repoID: UUID, labels: [RequiredLabel])

    /// The button's text. Named here rather than in the view for the reason
    /// `RepoFix.label` is: two screens must not spell the same act two ways.
    public var label: String {
        switch self {
        case .createLabels(_, _, let labels):
            // The count is in the text on purpose: "Create labels" on a row
            // listing four of them is a button whose blast radius is guesswork.
            "Create \(labels.count) label\(labels.count == 1 ? "" : "s")"
        case .seedCard:
            "Add a card"
        case .adoptLabelPolicy(_, let labels):
            // Says what it settles, not what it changes: it changes nothing
            // about which labels are checked. The count is present for
            // `createLabels`' reason — a button whose scope is guesswork.
            "Require these \(labels.count)"
        }
    }

    public var id: String {
        switch self {
        case .createLabels(let repoID, _, let labels):
            "createLabels:\(repoID):\(labels.map(\.name).joined(separator: ","))"
        case .seedCard(let repoID, let title, _, let key):
            key ?? "seedCard:\(repoID):\(title)"
        case .adoptLabelPolicy(let repoID, let labels):
            "adoptLabelPolicy:\(repoID):\(labels.map(\.name).joined(separator: ","))"
        }
    }

    /// Which repository this acts on.
    ///
    /// Carried by the fix rather than inferred from where its button sits: the
    /// Preflight screen renders checks for several repositories from one list,
    /// and a button that had to be told its repository by its position on screen
    /// is a fix applied to the wrong one waiting to happen.
    public var repoID: UUID {
        switch self {
        case .createLabels(let repoID, _, _), .seedCard(let repoID, _, _, _),
            .adoptLabelPolicy(let repoID, _):
            repoID
        }
    }
}

public struct CheckResult: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var status: CheckStatus
    public var detail: String
    /// The command that produced this verdict, so the user can run it
    /// themselves rather than take Elliot's word for it.
    public var command: String?
    public var fixHint: String?
    /// What Preflight can do about this finding, if anything.
    ///
    /// Plural from the start, and defaulted to empty so not one existing check
    /// grows a button by accident. Plural because the labels check already needs
    /// two — a singular `fix` would have to be widened by the second check that
    /// offers a choice, and that check is the one shipping with it.
    public var fixes: [CheckFix]

    public init(
        id: String,
        title: String,
        status: CheckStatus,
        detail: String,
        command: String? = nil,
        fixHint: String? = nil,
        fixes: [CheckFix] = []
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
        self.command = command
        self.fixHint = fixHint
        self.fixes = fixes
    }
}

/// Everything that has to be true before a card can be dragged.
public struct PreflightService: Sendable {
    private let environment: LoginShellEnvironment
    private let config: ToolConfig
    private let gh: GHClient
    private let git: GitClient

    public init(environment: LoginShellEnvironment, config: ToolConfig) {
        self.environment = environment
        self.config = config
        self.gh = GHClient(config: config)
        self.git = GitClient(config: config)
    }

    // MARK: - Global

    /// - Parameter packs: the methods this machine's repositories actually run.
    ///   A plugin check per pack, rather than one hardcoded name — which is what
    ///   made "the method Elliot drives" a property of the build instead of a
    ///   property of the repository.
    /// - Parameter overrides: the `ELLIOT_<TOOL>_PATH` variables in force. A parameter with a
    ///   default rather than a `ProcessInfo` read buried in the body, for `labelsCheck(policy:)`'s
    ///   reason: a suite cannot mutate the process environment without breaking every other suite
    ///   running beside it, and the rows below now *report* on an override rather than only obeying
    ///   one.
    public func globalChecks(
        layout: RepoTreeLayout = .portfolio,
        packs: [MethodPack],
        overrides: ToolOverrides = .fromProcessEnvironment()
    ) async -> [CheckResult] {
        var results: [CheckResult] = []

        // ⛔ Started first and awaited last. The handshake is a spawn plus two round trips —
        // measured at 2.41 s warm and 8.72 s cold (`AdapterHandshake`'s doc comment carries the
        // table) — and `globalChecks` is awaited inline by `AppModel.start()`, so running it
        // *beside* the tool probes rather than after them is the difference between a launch that
        // pays for it and one that hides it.
        async let adapter = probeAdapter()

        results.append(CheckResult(
            id: "env.loginShell",
            title: "Login shell environment",
            status: environment.capturedVia == "fallback" ? .warn : .pass,
            detail: environment.capturedVia == "fallback"
                ? "Could not read the login shell; using a built-in PATH. Tools may be missing."
                : "Captured via \(environment.capturedVia) — \(environment.searchPaths.count) PATH entries.",
            command: "/bin/zsh -lic 'env -0'"
        ))

        let locator = ToolLocator(environment: environment, overrides: overrides)
        // ⛔ **No `claude` row.** Since #381's task 15 nothing spawns that binary: a card's run is
        // an ACP adapter, and the adapter resolves the CLI vendored inside its own npm dependency
        // (`@anthropic-ai/claude-agent-sdk`) rather than the `claude` on this PATH. Reporting the
        // version of a binary that no longer runs is a confident claim about the wrong thing —
        // which is worse than saying nothing, because it reads as having been checked. The four
        // rows that replace it are below, and they describe what really spawns.
        for (tool, path) in [("gh", config.ghPath), ("git", config.gitPath)] {
            let resolution = await locator.locate(tool)
            // ⛔ An override that names an unusable path is its own row, ahead of
            // everything else: "not found — put it on your PATH" is the wrong
            // remedy for someone who *did* say which binary to use and mistyped
            // it, and sending them to install software they already have is how
            // a diagnostic wastes the time it exists to save (#238).
            if case .overrideUnusable(let variable, let value) = resolution {
                results.append(CheckResult(
                    id: "tool.\(tool)",
                    title: tool,
                    status: .fail,
                    detail: "\(variable) is set to \(value), which is not an executable file. "
                        + "Elliot will not fall back to your PATH — it would run a different "
                        + "binary than the one you named.",
                    command: "ls -l \(value)",
                    fixHint: "Point \(variable) at an executable, or unset it to use your PATH, "
                        + "then relaunch Elliot."
                ))
                continue
            }
            let located = resolution.tool
            let found = FileManager.default.isExecutableFile(atPath: path)
            // Says so when an override is in force. A change to which binary
            // runs must be visible on the screen that reports which binary runs.
            let source = located?.foundVia == "user override"
                ? " — set by \(ToolOverrides.variableName(for: tool))"
                : ""
            results.append(CheckResult(
                id: "tool.\(tool)",
                title: tool,
                status: found ? .pass : .fail,
                detail: found
                    ? [located?.resolvedPath ?? path, located?.version].compactMap { $0 }.joined(separator: " — ")
                        + source
                    : "Not found. An app launched from the Finder does not inherit your shell PATH.",
                command: "command -v \(tool)",
                // Names the real remedy. There is no Settings screen anywhere
                // in this product and nothing that persists a tool path, so the
                // previous hint sent the one user who most needs help to a
                // window that does not exist.
                fixHint: found
                    ? nil
                    : "Elliot reads your login shell's PATH. Put \(tool) on it, then press Check "
                        + "again — or name one with \(ToolOverrides.variableName(for: tool))."
            ))
        }

        // What the adapter is reached *through*. Both resolved by `ACPAgentLocator`, which is the
        // same resolution `AppModel` performs at launch to build `ToolConfig.adapterExecutable` —
        // so a red row here and an empty adapter argv are the same fact, said once each.
        let agentLocator = ACPAgentLocator(environment: environment, overrides: overrides)
        results.append(Self.nodeCheck(ACPAgentLocator.nodeVerdict(await agentLocator.resolveNode())))
        results.append(Self.npxCheck(await agentLocator.resolveNpx()))
        if let claudeOverride = overrides["claude"] {
            results.append(Self.retiredClaudeOverrideCheck(claudeOverride))
        }

        let probe = await adapter
        results.append(Self.adapterCheck(probe))
        results.append(Self.commandsCheck(probe, packs: packs))

        let authenticated = await gh.isAuthenticated()
        let login = authenticated ? try? await gh.login() : nil
        results.append(CheckResult(
            id: "gh.auth",
            title: "GitHub authentication",
            status: authenticated ? .pass : .fail,
            detail: authenticated ? "Signed in as \(login ?? "?")." : "gh is not authenticated.",
            command: "gh auth status",
            fixHint: authenticated ? nil : "Run `gh auth login -h github.com` in a terminal."
        ))

        // A plugin check per pack this machine's repositories actually run,
        // rather than one hardcoded name — `pack.plugin` is the measured
        // three-way split `PluginRequirement` exists to carry, and each case
        // means something different here:
        for pack in packs {
            switch pack.plugin {
            case .none:
                // ⛔ Skipped, never failed. A method that needs no plugin — GSD's
                // and Spec Kit's own tooling writes straight into the checkout —
                // must not read as a method whose plugin is missing: that would
                // be a `.fail` for a correct setup, and a red row nobody can
                // clear is a red row people learn to skim.
                continue
            case .required(let plugin):
                // ⚠️ The id is `plugin.<pack.id>`, so the default pack's row
                // moves from `plugin.aiMigrationKit` to `plugin.ai-migration-kit`.
                // Nothing reads it, and the change is deliberate.
                results.append(pluginCheck(
                    id: "plugin.\(pack.id)",
                    title: "\(plugin) skills",
                    plugin: plugin,
                    required: Self.requiredSkills(of: pack)
                ))
            case .unestablished(let reason):
                // Nothing is established as missing, so this is a `.warn`
                // carrying the reason — never a silent skip (which would read as
                // "checked, fine") and never a `.fail` (nothing has been shown
                // to be absent). This is the conflation `PluginRequirement`
                // exists to end, one layer up.
                results.append(CheckResult(
                    id: "plugin.\(pack.id)", title: "\(pack.displayName) plugin",
                    status: .warn, detail: reason,
                    fixHint: "Confirm whether \(pack.displayName) ships a Claude Code plugin, "
                        + "then record it in MethodCatalog."
                ))
            }
        }
        results.append(pluginCheck(
            id: "plugin.superpowers",
            title: "superpowers skills",
            plugin: "superpowers",
            required: ["using-git-worktrees", "test-driven-development"],
            statusWhenMissing: .warn
        ))

        results.append(Self.repositoriesRootCheck(layout))

        return results
    }

    /// Static so it is testable without a `PreflightService`, which needs a
    /// captured shell environment.
    public static func repositoriesRootCheck(_ layout: RepoTreeLayout) -> CheckResult {
        let expected = layout.ownerDirectories()
        let present = expected.filter { FileManager.default.fileExists(atPath: $0) }
        return CheckResult(
            id: "repositories.root", title: "Repository tree",
            status: present.isEmpty ? .fail : (present.count == expected.count ? .pass : .warn),
            detail: present.isEmpty
                ? "No owner folder found under \(layout.root)."
                : "\(present.count) of \(expected.count) owner folders under \(layout.root).",
            command: "ls -1 \(layout.root)",
            fixHint: present.count == expected.count
                ? nil : "Set the tree root on the Repositories page.")
    }

    // MARK: - The binary that actually runs

    /// Spawns the adapter in a scratch directory, asks who it is, and ends it.
    ///
    /// The directory is thrown away rather than being a real checkout: no `session/prompt` is ever
    /// sent so nothing executes, but `session/new` takes a working directory and there is no reason
    /// to hand an unattended agent one of Philippe's.
    private func probeAdapter() async -> AdapterProbe {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("elliot-preflight-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        return await AdapterHandshake.probe(agent: ACPAgentProcess(
            executable: config.adapterExecutable,
            arguments: config.adapterArguments,
            cwd: scratch.path,
            environment: config.environment
        ))
    }

    /// The `node` row — **five renderings, because `nodeVerdict` has five answers.**
    ///
    /// ⛔ The plan prescribed two failing sentences, *"Not found."* and *"Found X, but the adapter
    /// needs 22 or newer."*, for a question with three losing answers. A `.found` tool whose
    /// `version` is nil would have rendered as `"Found " + nothing`, and a reader running Node 26
    /// whose `--version` probe happened to fail would have been told their Node was too old.
    /// **Elliot never established that**, and the two unreadable cases are `.warn` rather than
    /// `.fail` for the same reason: on this screen a `.fail` means *cards cannot be dragged*, and
    /// nothing here has shown that anything is wrong.
    ///
    /// `static` and pure, so the whole matrix is assertable without a toolchain on disk.
    public static func nodeCheck(_ verdict: ACPAgentLocator.NodeVerdict) -> CheckResult {
        let floor = ACPAgentLocator.minimumNodeMajor
        switch verdict {
        case .ok(let tool, _):
            return CheckResult(
                id: "tool.node", title: "Node", status: .pass,
                detail: [tool.resolvedPath, tool.version].compactMap { $0 }.joined(separator: " — ")
                    + Self.overrideSuffix(tool),
                command: "node --version"
            )
        case .tooOld(let tool, let found):
            return CheckResult(
                id: "tool.node", title: "Node", status: .fail,
                detail: "Found \(found) at \(tool.resolvedPath), but the adapter needs "
                    + "\(floor) or newer.",
                command: "node --version",
                fixHint: "Install Node \(floor) or newer, then relaunch Elliot — or name one with "
                    + ToolOverrides.variableName(for: "node") + "."
            )
        case .unreadable(let tool, let reported):
            // Two sentences for two different silences — `--version` failed outright, or it
            // succeeded and said something that is not a version — sharing one conclusion, which
            // is the only thing Elliot has actually established.
            let what = reported.map { "which answered \"\($0)\" — not a version." }
                ?? "but `node --version` could not be run."
            return CheckResult(
                id: "tool.node", title: "Node", status: .warn,
                detail: "Found \(tool.resolvedPath), \(what) Elliot has no reading of this "
                    + "toolchain, so it cannot say whether it meets the floor of \(floor).",
                command: "\(tool.path) --version",
                fixHint: "Run `\(tool.path) --version` and see what it says."
            )
        case .overrideUnusable(let variable, let value):
            return Self.unusableOverrideCheck(id: "tool.node", title: "Node", variable: variable, value: value)
        case .missing:
            return CheckResult(
                id: "tool.node", title: "Node", status: .fail,
                detail: "Not found. The ACP adapter runs on Node \(floor) or newer, and an app "
                    + "launched from the Finder does not inherit your shell PATH.",
                command: "command -v node",
                fixHint: "Install Node \(floor) or newer and put it on your login shell's PATH, "
                    + "then relaunch Elliot — or name one with "
                    + ToolOverrides.variableName(for: "node") + "."
            )
        }
    }

    /// The `npx` row — three renderings, not five: nothing reads npx's version, so there is no
    /// floor for it to be under and nothing for Elliot to fail to read.
    public static func npxCheck(_ resolution: ToolResolution) -> CheckResult {
        switch resolution {
        case .found(let tool):
            return CheckResult(
                id: "tool.npx", title: "npx", status: .pass,
                detail: [tool.resolvedPath, tool.version].compactMap { $0 }.joined(separator: " — ")
                    + Self.overrideSuffix(tool),
                command: "npx --version"
            )
        case .overrideUnusable(let variable, let value):
            return Self.unusableOverrideCheck(id: "tool.npx", title: "npx", variable: variable, value: value)
        case .notFound:
            return CheckResult(
                id: "tool.npx", title: "npx", status: .fail,
                detail: "Not found. It ships with Node.",
                command: "command -v npx",
                fixHint: "Install Node, then relaunch Elliot — or name npx with "
                    + ToolOverrides.variableName(for: "npx") + "."
            )
        }
    }

    /// ⛔ **`ELLIOT_CLAUDE_PATH` stopped selecting anything, and it has to be named where it died.**
    /// Otherwise an operator who set it reads a green Preflight and gets a binary they did not
    /// choose — which is #238's failure shape wearing the clothes of the fix for it.
    ///
    /// Only built when the variable is actually set: a row nagging every reader about a variable
    /// they never used is a row people learn to skim.
    ///
    /// ⚠️ **The escape hatch is named and its status is stated, not implied.** `CLAUDE_CODE_EXECUTABLE`
    /// is what the adapter documents; whether pointing it at a locally installed CLI works has
    /// **not been measured**, and saying so is the difference between a hint and a claim. ⛔ Elliot
    /// does not silently repoint the variable at the adapter either: substituting a different
    /// meaning for something the reader set is the very thing this row exists to report.
    public static func retiredClaudeOverrideCheck(_ value: String) -> CheckResult {
        CheckResult(
            id: "tool.claudeOverride",
            title: "ELLIOT_CLAUDE_PATH",
            status: .warn,
            detail: "Set to \(value), and it no longer selects the CLI: the adapter runs the copy "
                + "vendored inside @anthropic-ai/claude-agent-sdk. The documented escape hatch is "
                + "CLAUDE_CODE_EXECUTABLE, and whether pointing it at a local install works is "
                + "unmeasured.",
            command: "printenv ELLIOT_CLAUDE_PATH",
            fixHint: "Unset it, or set CLAUDE_CODE_EXECUTABLE instead and check what actually ran."
        )
    }

    /// What the adapter calls itself, beside what Elliot pinned.
    ///
    /// ⚠️ **A drift is a `.warn`, never a `.pass`** — decision 10. Every fact this design rests on
    /// was measured against `\(ACPAgentLocator.adapterVersion)`, and a pin that has silently
    /// stopped being what runs is worse than no pin at all.
    ///
    /// ⚠️ A deadline that expired is also a `.warn` and not a `.fail`: *"it did not answer within
    /// N seconds"* is a true statement about Elliot's patience, not a finding about the adapter.
    /// Only an adapter that answered *something wrong* — a spawn error, a JSON-RPC error — fails,
    /// and its own words are what the row shows.
    public static func adapterCheck(_ probe: AdapterProbe) -> CheckResult {
        let pinned = ACPAgentLocator.adapterVersion
        guard probe.answered else {
            switch probe.failure {
            case .silent(let deadline):
                return CheckResult(
                    id: "agent.adapter", title: "ACP adapter", status: .warn,
                    detail: "The adapter did not answer within \(Self.seconds(deadline)) seconds, "
                        + "so Elliot ended it. Nothing was established about it either way.",
                    command: "npx --yes \(ACPAgentLocator.adapterPackage)",
                    fixHint: "Run that command in a terminal and see how far it gets."
                )
            case .error(let message):
                return CheckResult(
                    id: "agent.adapter", title: "ACP adapter", status: .fail,
                    // Verbatim. Elliot paraphrasing a JSON-RPC error is Elliot inventing one.
                    detail: message,
                    command: "npx --yes \(ACPAgentLocator.adapterPackage)",
                    fixHint: "Every card that moves spawns this. Nothing will run until it does."
                )
            case nil:
                // Unreachable by construction — `probe` sets a failure whenever nothing answered —
                // and said out loud rather than folded into one of the arms above, which would put
                // a sentence about a cause nobody established on the screen that must be believed.
                return CheckResult(
                    id: "agent.adapter", title: "ACP adapter", status: .warn,
                    detail: "Could not be established: the handshake reported neither an identity "
                        + "nor a reason.",
                    command: "npx --yes \(ACPAgentLocator.adapterPackage)"
                )
            }
        }

        let named = [probe.agentName, probe.agentVersion].compactMap { $0 }.joined(separator: " ")
        guard probe.agentVersion == pinned else {
            return CheckResult(
                id: "agent.adapter", title: "ACP adapter", status: .warn,
                detail: "\(named) — but Elliot pins \(pinned), which is the version every fixture "
                    + "in this design was measured against.",
                command: "npx --yes \(ACPAgentLocator.adapterPackage)",
                fixHint: "Raising the pin is a code change that re-takes those measurements."
            )
        }
        return CheckResult(
            id: "agent.adapter", title: "ACP adapter", status: .pass,
            detail: "\(named) — pinned at \(pinned).",
            command: "npx --yes \(ACPAgentLocator.adapterPackage)"
        )
    }

    /// Does the agent Elliot is about to drive actually offer the commands it dispatches?
    ///
    /// ⛔ **Not the same question as the `~/.claude/plugins/cache` walk, which stays.** That one
    /// answers *is the plugin installed on this machine*; this one answers *does the agent
    /// advertise it*, which is what a failed drag actually turns on. The design says the walk "is
    /// complemented, not replaced" by asserting the commands are advertised — this is where that
    /// sentence stops being a slogan.
    ///
    /// ⛔ **`nil` commands is a `.warn`, never a list of missing ones.** *"The adapter advertises
    /// none"* and *"nobody could ask"* are different facts, and reporting the first on the evidence
    /// of the second is `isBlocking([])`'s two-valued answer wearing a new hat.
    ///
    /// The expected set is derived from `packs`, not hardcoded: it is the same `/<plugin>:<skill>`
    /// list the `plugin.<pack.id>` rows are built from, so a repository that chose another method
    /// cannot be judged against ai-migration-kit's commands.
    public static func commandsCheck(_ probe: AdapterProbe, packs: [MethodPack]) -> CheckResult {
        let expected = Self.dispatchedCommands(packs)
        guard let advertised = probe.commands else {
            return CheckResult(
                id: "agent.commands", title: "Agent commands", status: .warn,
                detail: "Could not be established: \(Self.sentence(probe.failure)) So Elliot cannot "
                    + "say whether the commands it dispatches are offered.",
                command: "python3 Scripts/probe/acp_probe.py"
            )
        }
        let present = Set(advertised)
        let missing = expected.filter { !present.contains($0) }
        guard missing.isEmpty else {
            return CheckResult(
                id: "agent.commands", title: "Agent commands", status: .fail,
                detail: "Missing: \(missing.joined(separator: ", ")). "
                    + "\(advertised.count) commands advertised, and a card that reaches one of "
                    + "these will spawn an agent that cannot run it.",
                command: "python3 Scripts/probe/acp_probe.py",
                fixHint: "Install the plugin these come from in Claude Code, then relaunch Elliot."
            )
        }
        return CheckResult(
            id: "agent.commands", title: "Agent commands", status: .pass,
            detail: expected.isEmpty
                ? "\(advertised.count) advertised. No method registered here dispatches a plugin "
                    + "command, so there is nothing in particular to look for."
                : "\(advertised.count) advertised, including \(expected.joined(separator: ", ")).",
            command: "python3 Scripts/probe/acp_probe.py"
        )
    }

    /// The `<plugin>:<skill>` commands the machine's methods dispatch, as the adapter names them.
    ///
    /// Sorted and de-duplicated, for `requiredSkills`' reason: `steps` is a dictionary and has no
    /// order, and a detail string that reshuffled between sweeps reads as something changing.
    public static func dispatchedCommands(_ packs: [MethodPack]) -> [String] {
        var found: Set<String> = []
        for pack in packs {
            guard case .required(let plugin) = pack.plugin else { continue }
            for skill in Self.requiredSkills(of: pack) { found.insert("\(plugin):\(skill)") }
        }
        return found.sorted()
    }

    /// One sentence for a failure, so `commandsCheck` explains an absence rather than asserting a
    /// finding. `nil` is a real case: the session opened and the stream simply ended.
    private static func sentence(_ failure: AdapterProbe.Failure?) -> String {
        switch failure {
        case .silent(let deadline):
            "the adapter did not answer within \(Self.seconds(deadline)) seconds."
        case .error(let message):
            message.hasSuffix(".") ? message : message + "."
        case nil:
            "the adapter advertised nothing and gave no reason."
        }
    }

    private static func seconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds)
    }

    /// ` — set by ELLIOT_<TOOL>_PATH` when one is in force, and empty otherwise. A change to which
    /// binary runs must be visible on the screen that reports which binary runs (#238).
    private static func overrideSuffix(_ tool: LocatedTool) -> String {
        tool.foundVia == "user override"
            ? " — set by \(ToolOverrides.variableName(for: tool.name))" : ""
    }

    /// ⛔ An override that names an unusable path is its own finding, and never "not found — put it
    /// on your PATH": sending someone who mistyped a path off to install software they already have
    /// is how a diagnostic wastes the time it exists to save (#238). One implementation, so the
    /// three tools that can carry an override cannot word it three ways.
    private static func unusableOverrideCheck(
        id: String, title: String, variable: String, value: String
    ) -> CheckResult {
        CheckResult(
            id: id, title: title, status: .fail,
            detail: "\(variable) is set to \(value), which is not an executable file. Elliot will "
                + "not fall back to your PATH — it would run a different binary than the one you "
                + "named.",
            command: "ls -l \(value)",
            fixHint: "Point \(variable) at an executable, or unset it to use your PATH, then "
                + "relaunch Elliot."
        )
    }

    /// The newest installed version of a plugin, and whether it carries the
    /// skills Elliot dispatches.
    private func pluginCheck(
        id: String,
        title: String,
        plugin: String,
        required: [String],
        statusWhenMissing: CheckStatus = .fail
    ) -> CheckResult {
        guard let root = Self.pluginRoot(plugin) else {
            return CheckResult(
                id: id, title: title, status: statusWhenMissing,
                detail: "Not installed under ~/.claude/plugins/cache.",
                fixHint: "Install the \(plugin) plugin in Claude Code."
            )
        }
        let missing = required.filter {
            !FileManager.default.fileExists(atPath: root.appendingPathComponent("skills/\($0)/SKILL.md").path)
        }
        return CheckResult(
            id: id, title: title,
            status: missing.isEmpty ? .pass : statusWhenMissing,
            detail: missing.isEmpty
                ? "Found at \(root.lastPathComponent) with all required skills."
                : "Missing: \(missing.joined(separator: ", "))",
            command: "ls \(root.path)/skills"
        )
    }

    /// Highest installed semver of a plugin.
    public static func pluginRoot(_ plugin: String) -> URL? {
        let cache = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/plugins/cache")
        guard let marketplaces = try? FileManager.default.contentsOfDirectory(
            at: cache, includingPropertiesForKeys: nil
        ) else { return nil }

        var best: (URL, [Int])?
        for marketplace in marketplaces {
            let pluginDir = marketplace.appendingPathComponent(plugin)
            guard let versions = try? FileManager.default.contentsOfDirectory(
                at: pluginDir, includingPropertiesForKeys: nil
            ) else { continue }
            for version in versions {
                let parts = version.lastPathComponent.split(separator: ".").map { Int($0) ?? 0 }
                if best == nil || parts.lexicographicallyPrecedes(best!.1) == false {
                    best = (version, parts)
                }
            }
        }
        return best?.0
    }

    // MARK: - Per repo

    public func repoChecks(_ repo: Repo) async -> [CheckResult] {
        var results: [CheckResult] = []

        let isRepo = (try? await git.topLevel(cwd: repo.path)) != nil
        results.append(CheckResult(
            id: "repo.exists", title: "Git repository",
            status: isRepo ? .pass : .fail,
            detail: isRepo ? repo.path : "\(repo.path) is not a git repository.",
            command: "git -C \(repo.path) rev-parse --show-toplevel"
        ))
        guard isRepo else { return results }

        // merge-pr removes the pull request's worktree and cannot do that from
        // inside one, so a linked worktree would fail at the last step.
        let isMain = await git.isMainCheckout(path: repo.path)
        results.append(CheckResult(
            id: "repo.isMainCheckout", title: "Main checkout",
            status: isMain ? .pass : .fail,
            detail: isMain
                ? "This is the main checkout."
                : "This is a linked worktree. merge-pr must run from the main checkout.",
            command: "git -C \(repo.path) rev-parse --git-common-dir",
            fixHint: isMain ? nil : "Register the main checkout instead."
        ))

        if let terms = Self.runTermsCheck(repo) { results.append(terms) }

        // Which method this repository runs, in three values rather than two.
        // `.unknown` is the one that blocks: we do not know what to run, and
        // running some other method's commands unannounced is worse than
        // refusing — the silent substitution `MethodResolution` exists to stop.
        let pack: MethodPack?
        switch repo.method {
        case .unset(let chosen):
            pack = chosen
            results.append(CheckResult(
                id: "repo.method", title: "Method", status: .pass,
                // "Not chosen" and "chose the default" run the same commands and
                // are different facts: only one of them follows the default if
                // it ever moves.
                detail: "Not chosen — using \(chosen.displayName). \(chosen.summary)",
                fixHint: "Pick one on the Repositories page."
            ))
        case .chosen(let chosen):
            pack = chosen
            results.append(CheckResult(
                id: "repo.method", title: "Method", status: .pass,
                detail: "\(chosen.displayName). \(chosen.summary)"
            ))
        case .unknown(let id):
            pack = nil
            results.append(CheckResult(
                id: "repo.method", title: "Method", status: .fail,
                detail: "Set to \"\(id)\", which this build has no pack for. "
                    + "Nothing will be dragged here until it names a method Elliot knows.",
                fixHint: "Pick one of "
                    + MethodCatalog.builtIn.map(\.id).sorted().joined(separator: ", ")
                    + " on the Repositories page."
            ))
        }

        let profileURL = URL(fileURLWithPath: repo.path).appendingPathComponent(Self.profilePath)
        let profileExists = FileManager.default.fileExists(atPath: profileURL.path)
        // `.fail` only when this method dispatches plugin skills: the profile is
        // the config *those* read at their preconditions step. A method that
        // dispatches none — GSD's `/gsd-plan-phase`, plain plan mode — has
        // nothing that opens the file, and freezing its board over an absence
        // that costs it nothing is #249's gate answering the wrong question.
        let dispatchesSkills = pack.map { !Self.requiredSkills(of: $0).isEmpty } ?? false
        results.append(CheckResult(
            id: "repo.profile", title: "Repo profile",
            status: profileExists ? .pass : (dispatchesSkills ? .fail : .warn),
            detail: profileExists
                ? Self.profilePath
                : "No \(Self.profilePath); the skills read it at their preconditions step.",
            command: "cat \(profileURL.path)",
            fixHint: profileExists ? nil : Self.profileHint(pack)
        ))

        if profileExists {
            // An untracked profile does not exist inside a fresh worktree, and
            // implement-issue works from one.
            let tracked = await git.isTracked(path: Self.profilePath, in: repo.path)
            results.append(CheckResult(
                id: "repo.profileCommitted", title: "Profile committed",
                status: tracked ? .pass : .warn,
                detail: tracked
                    ? "Tracked by git."
                    : "Untracked — it will be missing inside the worktrees implement-issue creates.",
                command: "git -C \(repo.path) ls-files --error-unmatch \(Self.profilePath)",
                fixHint: tracked ? nil : "git add \(Self.profilePath) && git commit"
            ))
        }

        let info = try? await gh.repoInfo(cwd: repo.path)
        results.append(CheckResult(
            id: "repo.nameWithOwner", title: "GitHub repository",
            status: info != nil ? .pass : .fail,
            detail: info?.nameWithOwner ?? "gh could not identify a GitHub remote.",
            command: "gh repo view --json nameWithOwner,defaultBranchRef"
        ))

        let clean = await git.isClean(cwd: repo.path)
        results.append(CheckResult(
            id: "repo.clean", title: "Working tree",
            status: clean ? .pass : .warn,
            detail: clean ? "Clean." : "Uncommitted changes; a skill may pick them up.",
            command: "git -C \(repo.path) status --porcelain"
        ))

        // Only worth asking once GitHub has identified the repository — without
        // a `nameWithOwner` there is nothing to ask `gh` about, and the check
        // above already reports that.
        if let nameWithOwner = info?.nameWithOwner {
            results.append(await labelsCheck(repo, nameWithOwner: nameWithOwner))
        }

        // The method's project requirements, last: they are the only checks here
        // that depend on which method this repository chose, and an `.unknown`
        // one has no requirements to look for — reporting another pack's would
        // be the substitution the `.fail` above refuses.
        if let pack {
            results.append(contentsOf: await projectResults(repo: repo, pack: pack))
        }

        return results
    }

    /// The extra allowed tools that ACP cannot grant, met on a screen instead of in a failed run.
    ///
    /// ⛔ **A `.fail`, deliberately, and it really does freeze this repository's board.** That is
    /// not this row overreaching — it is the row telling the truth about a repository where *every*
    /// drag already refuses: `AgentRun.start` throws `unmappableAllowedTools` before it constructs
    /// an `AgentSession`, so nothing spawns and every card fails the instant it moves. Since #249 a
    /// `.fail` means "cards cannot be dragged in this repository", which is exactly what is the
    /// case. A `.warn` here would draw a board that looks movable and is not.
    ///
    /// ⚠️ The adapter advertises five config options — `mode`, `model`, `effort`, `fast`, `agent`
    /// — and **none for allowed tools** (`Fixtures/acp/session-new-commands.json`). So this is not
    /// a gap Elliot can close by spelling something differently; dropping the grant silently would
    /// let a run meet a refusal for a tool the operator had explicitly allowed.
    ///
    /// `nil` when there is nothing to say. A repository that allows nothing extra — the common
    /// case, and every repository until #333 gave the column a writer — grows no row at all.
    ///
    /// The remedy names the same screen `AgentInvocationError.unmappableAllowedTools` names, so the
    /// operator who meets this before a drag and the one who meets it after are sent to one place.
    public static func runTermsCheck(_ repo: Repo) -> CheckResult? {
        guard !repo.extraAllowedTools.isEmpty else { return nil }
        return CheckResult(
            id: "repo.runTerms", title: "Run terms", status: .fail,
            detail: "\(repo.extraAllowedTools.joined(separator: ", ")) cannot be granted: the ACP "
                + "adapter advertises no config option for allowed tools. Every run in this "
                + "repository will refuse to start rather than drop the grant silently.",
            fixHint: "Clear the extra allowed tools in Preflight ▸ this repository ▸ Run terms."
        )
    }

    /// Whether this repository has the labels Elliot's skills apply.
    ///
    /// **A warning, never a failure.** `PreflightReading.verdict` calls any
    /// `.fail` "cards cannot be dragged in this repository", and a missing
    /// `documentation` label must not freeze a board.
    ///
    /// ⚠️ That reasoning was sound and its premise was not: until #249 a `.fail`
    /// froze nothing, so this check was shaped around a consequence that did not
    /// exist. The shape happens to be right — a missing label costs an issue
    /// filed without it, which is not grounds to stop the board — but it was
    /// right by accident for as long as the gate was missing. It is load-bearing
    /// now, so promoting this to `.fail` really would freeze a board. What a missing label costs is an issue
    /// filed without it: `create-issue`'s own instructions say *"if a chosen
    /// label isn't in the live list, create without it rather than failing, and
    /// flag the gap"* — so today the card moves, the issue is filed unlabelled,
    /// and nothing on the board says so. This is the thing that says so.
    ///
    /// `required` is a parameter with a default so a test can state a small
    /// policy instead of asserting against whatever `LabelPolicy.default` grows
    /// into.
    public func labelsCheck(
        _ repo: Repo,
        nameWithOwner: String? = nil,
        policy: LabelPolicy.Resolved? = nil
    ) async -> CheckResult {
        let target = nameWithOwner ?? repo.nameWithOwner
        // The repository's own answer when it has one, Elliot's floor when it
        // does not — resolved once, so nothing below has to remember which.
        let policy = policy ?? LabelPolicy.resolved(for: repo)

        guard let present = try? await gh.labels(repo: target) else {
            // ⚠️ Not "every label is missing". A failure to *ask* is not a
            // finding about the answer — the same duty #148 records one screen
            // over — and offering a create button here would act on a guess
            // about a repository nobody could reach.
            return CheckResult(
                id: "repo.labels", title: "Labels", status: .warn,
                detail: "Could not be established: gh did not answer for \(target).",
                command: "gh label list --repo \(target)",
                fixHint: "Check `gh auth status` and that the repository is reachable."
            )
        }

        let missing = LabelPolicy.missing(required: policy.required, present: present)
        guard !missing.isEmpty else {
            // ⚠️ **A pass, and possibly still an unanswered question.** These are
            // two different things and this check conflated them until #200:
            // *"are the labels this policy names present?"* is about GitHub's
            // state, and *"has anyone decided what this repository should
            // require?"* is about the repository — and a `.pass` on the first
            // cannot answer the second. The floor is GitHub's four stock labels,
            // deliberately chosen in #172 as something a fresh repository
            // already satisfies, so on the repositories that most need the
            // taxonomy conversation the check passed and offered **no fixes at
            // all**. Verified on phmatray/Elliot, which has all four.
            return CheckResult(
                id: "repo.labels", title: "Labels", status: .pass,
                detail: policy.isUndecided
                    ? "All \(policy.required.count) labels \(policy.whose) are present — but "
                        + "nobody has said what this repository should require, so Elliot's "
                        + "floor is what was applied."
                    : "All \(policy.required.count) labels \(policy.whose) are present.",
                command: "gh label list --repo \(target)",
                fixes: Self.taxonomyFixes(repo, policy: policy, satisfied: true)
            )
        }

        // Named one by one. "Some labels are missing" sends the reader to
        // GitHub to work out which, which is the work this check exists to do.
        let names = missing.map(\.name).joined(separator: ", ")
        return CheckResult(
            id: "repo.labels", title: "Labels", status: .warn,
            detail: "Missing: \(names). create-issue drops a label this repository "
                + "does not have, and files the issue anyway.",
            command: "gh label list --repo \(target)",
            fixes: [
                // The **resolved** name, not the stored one — see the case's
                // own comment for what diverges and what it costs.
                .createLabels(repoID: repo.id, nameWithOwner: target, labels: missing),
            ] + Self.taxonomyFixes(repo, policy: policy, satisfied: false)
        )
    }

    /// The two ways to answer *"what should this repository require?"*, offered
    /// only while it is unanswered.
    ///
    /// ⛔ **Empty once the repository has decided** — criterion 4 of #200. A
    /// repository that declared its own set, *including an empty one*, has given
    /// the answer, and re-offering the conversation would be nagging it for
    /// something it already said.
    ///
    /// The two are the `createLabels`/`seedCard` split CLAUDE.md draws, applied
    /// to a different question:
    ///
    /// - **Keeping the floor is deterministic** — one right answer, nothing
    ///   committed, no judgement — so it writes the column directly and runs no
    ///   agent. It changes *nothing* about what is checked; its whole effect is
    ///   to record that somebody looked, which is what stops the nag.
    /// - **Wanting a different taxonomy is a judgement that edits a committed
    ///   file** (`repo-profile.md`), so it goes on the board and through a pull
    ///   request. Reaching an unattended `claude -p` from a Preflight button
    ///   would be a second place outside the board that starts a run.
    /// `satisfied` is whether the policy in force is currently met, and it
    /// decides whether *keeping the floor* is offered at all.
    ///
    /// ⛔ Not offered while labels are missing, deliberately. "Require these
    /// four" beside "Create four labels" is two buttons for a reader who has
    /// been told what is absent, and adopting a policy the repository does not
    /// yet meet records a decision while leaving the warning standing — a muddle
    /// where the row is already doing its job. The reachability #200 is about is
    /// the **passing** row, which offered nothing at all.
    static func taxonomyFixes(
        _ repo: Repo, policy: LabelPolicy.Resolved, satisfied: Bool
    ) -> [CheckFix] {
        guard policy.isUndecided else { return [] }
        return (satisfied ? [.adoptLabelPolicy(repoID: repo.id, labels: policy.required)] : []) + [
            .seedCard(
                repoID: repo.id,
                title: "Decide this repository's label taxonomy",
                story: UserStory(
                    role: "maintainer of \(repo.nameWithOwner)",
                    want: "a label taxonomy recorded in .claude/skills/repo-profile.md",
                    benefit: "create-issue labels issues the way this repository wants, "
                        + "instead of dropping labels it cannot find",
                    acceptanceCriteria: [
                        "The profile's Labels section names a real taxonomy, not a TODO.",
                        "Every label it names exists on the repository.",
                        "Elliot's Preflight labels check passes for \(repo.nameWithOwner).",
                    ]
                ),
                // ⛔ `nil`, not a key of its own. `apply` hands `fix.id` to
                // `createCard(idempotencyKey:)`, and this fix's id — derived
                // from the title — is already the key of cards in the field.
                // A key here would let a second identical card be created for a
                // finding that had already been seeded.
                key: nil
            ),
        ]
    }

    // MARK: - The repository's method

    /// The one path both the profile check and its hint name.
    static let profilePath = ".claude/skills/repo-profile.md"

    /// The distinct methods a machine's repositories run, plus the default.
    ///
    /// The default is always in, even for an empty list: `globalChecks` runs at
    /// launch, before the repository table has been read, and a plugin check
    /// that silently disappeared on a fresh install would be "nobody looked"
    /// wearing a pass — `isBlocking([])`'s lesson, one screen over.
    ///
    /// `.unknown` contributes nothing. It has no pack, so it names no plugin;
    /// `repoChecks` fails it per repository, which is where the reader can act.
    public static func packsInUse(_ repos: [Repo]) -> [MethodPack] {
        var byID: [String: MethodPack] = [:]
        if case .unset(let fallback) = MethodCatalog.resolve(nil) { byID[fallback.id] = fallback }
        for repo in repos {
            switch repo.method {
            case .unset(let pack), .chosen(let pack): byID[pack.id] = pack
            case .unknown: continue
            }
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    /// The plugin skills this pack dispatches, read off its own step commands.
    ///
    /// Derived rather than declared, because `MethodPack` has no field for it
    /// and inventing one would put the same list in two places. A command of the
    /// shape `/<plugin>:<skill>` names a `SKILL.md` that must exist; anything
    /// else — GSD's `/gsd-plan-phase`, Spec Kit's `/speckit.specify` — names a
    /// command, and there is no skill directory to look for.
    ///
    /// Only meaningful for `.required(name)`: a pack whose plugin is `.none` or
    /// `.unestablished` has no established name to form the `/<plugin>:` prefix
    /// from, and no built-in pack in either state carries a `/<name>:<skill>`
    /// command anyway — GSD's and Spec Kit's commands use `-` and `.`, never `:`.
    ///
    /// **Sorted**, because `steps` is a dictionary and has no order: an unsorted
    /// list would make the check's own detail string reshuffle between sweeps,
    /// which reads as something changing. Alphabetical also happens to be the
    /// order the hardcoded list had, so the default pack's detail is unchanged
    /// byte for byte.
    public static func requiredSkills(of pack: MethodPack) -> [String] {
        guard case .required(let plugin) = pack.plugin else { return [] }
        let prefix = "/\(plugin):"
        return pack.steps.values
            .compactMap {
                $0.command.hasPrefix(prefix) ? String($0.command.dropFirst(prefix.count)) : nil
            }
            .sorted()
    }

    /// How to get a repo profile, in the resolved method's own words.
    public static func profileHint(_ pack: MethodPack?) -> String {
        guard let pack, case .required(let plugin) = pack.plugin else {
            return "Write \(profilePath) by hand — this method installs no plugin that writes it."
        }
        return "Run /\(plugin):get-repo-profile in this repo, or write \(profilePath) by hand."
    }

    // MARK: - The repository's project requirements

    /// The probe, the decision and the refusal, in one place a test can drive.
    ///
    /// ⛔ Extracted rather than inlined into `repoChecks`, and not for tidiness:
    /// `repoChecks` returns early on `guard isRepo`, which covers every case
    /// `ArtifactProbe` throws `.unreadable` for, so from inside `repoChecks` the
    /// `catch` is reachable **only** through malformed pack evidence — which no
    /// catalogue pack has. Left inline, the refusal arm could be deleted with
    /// every test still green. `PreflightMethodTests.malformedPackEvidenceReachesTheRefusal`
    /// drives this function with a hand-built pack;
    /// `missingArtefactWarnsAndDoesNotBlock` drives `repoChecks` end to end, so
    /// the two together also catch `repoChecks` ceasing to call it.
    ///
    /// An instance method rather than `static`, unlike its siblings below: it is
    /// reached in tests as `service().projectResults(...)`, alongside every
    /// other member of this service that touches disk or a tool, even though
    /// its own body needs no instance state.
    public func projectResults(repo: Repo, pack: MethodPack) async -> [CheckResult] {
        guard !pack.projectRequirements.isEmpty else { return [] }
        do {
            let satisfied = try ArtifactProbe(repoRoot: repo.path)
                .evaluate(pack.projectRequirements.map(\.evidence))
            return Self.projectChecks(repo: repo, pack: pack, satisfied: satisfied)
        } catch {
            return [Self.probeRefusal(pack: pack, repo: repo, error: error)]
        }
    }

    /// One `.warn` per missing project artefact — **never a `.fail`**.
    ///
    /// ⛔ Since #249 a `.fail` blocks every drag in that repository. A repository
    /// without a PRD, a constitution or a roadmap still works, and freezing its
    /// board over a file it has every right not to have would be absurd. The two
    /// verdicts are one character apart and only one of them is reversible by a
    /// reader, so the distinction is named here rather than left to the caller.
    ///
    /// `static` and pure: what the screen *says* is assertable without a disk.
    public static func projectChecks(
        repo: Repo, pack: MethodPack, satisfied: [MethodPack.Evidence: Bool]
    ) -> [CheckResult] {
        pack.projectGaps(satisfied: satisfied).map { requirement in
            CheckResult(
                id: "method.\(pack.id).\(requirement.id)",
                title: requirement.title,
                status: .warn,
                detail: "\(pack.displayName) expects \(sentence(requirement.evidence)); "
                    + "it is not there.",
                command: command(requirement.evidence, in: repo.path),
                fixHint: requirement.remedy,
                fixes: seedFix(requirement, pack: pack, repoID: repo.id)
            )
        }
    }

    /// "I could not look" is not "there is nothing there".
    ///
    /// **One** warning naming the cause, never N false gaps — the singular
    /// return type is the guarantee, not a convention. It is the same duty
    /// `labelsCheck` discharges when `gh` does not answer, and it carries no fix
    /// for the same reason: a button here would act on a guess about a checkout
    /// nobody could open.
    public static func probeRefusal(
        pack: MethodPack, repo: Repo, error: any Error
    ) -> CheckResult {
        CheckResult(
            id: "method.\(pack.id).probe",
            title: "\(pack.displayName) project files",
            status: .warn,
            detail: "Could not be established: \(error.localizedDescription)",
            command: "ls -1 \(repo.path)",
            fixHint: "Check that \(repo.path) is readable, then press Check again."
        )
    }

    /// Exhaustive with no `default:`: wave 2's GitHub evidence cases must fail
    /// to compile here so someone writes the sentence rather than inheriting a
    /// wrong one.
    private static func sentence(_ evidence: MethodPack.Evidence) -> String {
        switch evidence {
        case .file(let path): "the file \(path)"
        case .anyFileUnder(let directory): "at least one file under \(directory)"
        }
    }

    private static func command(_ evidence: MethodPack.Evidence, in root: String) -> String {
        switch evidence {
        case .file(let path): "ls -l \(root)/\(path)"
        case .anyFileUnder(let directory): "find \(root)/\(directory) -type f"
        }
    }

    /// The card this gap offers to file, keyed through the one function that
    /// builds that key — see `MethodPack.idempotencyKey(for:in:)`, and the
    /// board-wide uniqueness of `card_on_idempotencyKey` it exists to survive.
    ///
    /// A note-mode draft has no `UserStory` and `.seedCard` demands one, so the
    /// honest answer is no button — the remedy is still in `fixHint`.
    /// `MethodCatalogTests` pins every built-in seed as a story, so this guard is
    /// a floor rather than a path.
    private static func seedFix(
        _ requirement: ProjectRequirement, pack: MethodPack, repoID: UUID
    ) -> [CheckFix] {
        guard let story = requirement.seed.story else { return [] }
        return [.seedCard(
            repoID: repoID,
            title: requirement.seed.title,
            story: story,
            key: pack.idempotencyKey(for: requirement, in: repoID)
        )]
    }

    // MARK: - Acting on a finding

    /// Performs a `CheckFix`, and never throws into the view.
    ///
    /// Shaped on `RepoRegistryService.apply(_:layout:)` deliberately: two screens
    /// that both turn a diagnostic into an action should do it the same way, and
    /// the reason that one returns an outcome rather than throwing is that a
    /// button's failure is information for the reader, not an error for the app.
    ///
    /// `board` is passed in rather than held, because **`BoardService` is the
    /// only thing that creates a card** — the seed fix calls the funnel, it does
    /// not write a row.
    /// `store` is here for `adoptLabelPolicy` alone, which writes a repository
    /// row rather than touching `gh`. It is a parameter rather than a stored
    /// property because this service is built fresh per sweep from a
    /// `ToolConfig`, and giving it a database would make every check's
    /// construction depend on one.
    public func apply(
        _ fix: CheckFix, repo: Repo, board: BoardService, store: BoardStore? = nil
    ) async -> CheckFixOutcome {
        switch fix {
        case .createLabels(_, let nameWithOwner, let labels):
            var created: [String] = []
            var alreadyThere: [String] = []
            var failed: [String] = []
            for label in labels {
                do {
                    // The resolved name the *check* asked about, never the
                    // stored one — see `CheckFix.createLabels`.
                    if try await gh.createLabel(label, repo: nameWithOwner) {
                        created.append(label.name)
                    } else {
                        alreadyThere.append(label.name)
                    }
                } catch {
                    failed.append(label.name)
                }
            }
            guard failed.isEmpty else {
                // Named, and **not** reported as success. A partial run counted
                // as done is the same defect as a truncated page with no note:
                // the caller reads it as complete and stops looking.
                return CheckFixOutcome(
                    succeeded: false,
                    detail: created.isEmpty
                        ? "Could not create \(failed.joined(separator: ", "))."
                        : "Created \(created.joined(separator: ", ")); "
                            + "could not create \(failed.joined(separator: ", "))."
                )
            }
            // "Created" and "was already there" are kept apart on purpose.
            // `labels()` reads one page, so a repository past that page can
            // report a label missing that `gh label create` then refuses as
            // existing — and calling that "created" would put a sentence beside
            // a row that still says the label is missing. Two claims about the
            // same label, in the same panel, one of them false.
            var parts: [String] = []
            if !created.isEmpty {
                parts.append(
                    "Created \(created.count) label\(created.count == 1 ? "" : "s"): "
                        + created.joined(separator: ", "))
            }
            if !alreadyThere.isEmpty {
                parts.append(
                    "\(alreadyThere.joined(separator: ", ")) already existed — "
                        + "this repository has more labels than one page lists.")
            }
            return CheckFixOutcome(
                succeeded: true,
                detail: parts.isEmpty ? "Nothing to create." : parts.joined(separator: ". ") + "."
            )

        case .seedCard(_, let title, let story, _):
            do {
                // Backlog, where nothing runs. Seeding into `todo` would file an
                // issue the instant the button was pressed — a button that
                // starts an unattended agent is precisely what this design
                // refuses, and the card is how the agent is reached instead.
                _ = try await board.createCard(
                    repoID: repo.id, title: title, story: story, column: .backlog,
                    // The button does not disappear after a press — the labels
                    // are still missing, so the same row is rebuilt with the
                    // same two fixes. Without a key, a second press (or an
                    // impatient double-click, since nothing disables the button
                    // during the await) leaves two identical cards. `fix.id` is
                    // already a stable key for exactly this.
                    idempotencyKey: fix.id
                )
                return CheckFixOutcome(
                    succeeded: true,
                    detail: "Added a card to Backlog. Nothing has run — move it when you are ready."
                )
            } catch {
                return CheckFixOutcome(
                    succeeded: false, detail: "Could not add the card: \(error.localizedDescription)"
                )
            }

        case .adoptLabelPolicy(_, let labels):
            guard let store else {
                // Said out loud rather than reported as done. A fix that
                // silently no-ops is the failure this whole screen is being
                // taught to avoid.
                return CheckFixOutcome(
                    succeeded: false, detail: "Elliot is still starting; try again in a moment."
                )
            }
            do {
                var updated = repo
                updated.labelPolicy = labels
                try await store.saveRepo(updated)
                return CheckFixOutcome(
                    succeeded: true,
                    detail: labels.isEmpty
                        ? "This repository now requires no labels. Preflight will stop asking."
                        : "This repository now requires \(labels.count) "
                            + "label\(labels.count == 1 ? "" : "s"): "
                            + labels.map(\.name).joined(separator: ", ") + "."
                )
            } catch {
                return CheckFixOutcome(
                    succeeded: false,
                    detail: "Could not record the policy: \(error.localizedDescription)"
                )
            }
        }
    }
}

/// What a `CheckFix` did, said in a sentence the row can show.
///
/// The twin of `RepoFixOutcome`, and separate from it for the reason the two
/// enums are separate: one screen's vocabulary should not quietly become the
/// other's contract.
public struct CheckFixOutcome: Sendable, Hashable {
    public var succeeded: Bool
    public var detail: String

    public init(succeeded: Bool, detail: String) {
        self.succeeded = succeeded
        self.detail = detail
    }
}
