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
    case seedCard(repoID: UUID, title: String, story: UserStory)

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
        }
    }

    public var id: String {
        switch self {
        case .createLabels(let repoID, _, let labels):
            "createLabels:\(repoID):\(labels.map(\.name).joined(separator: ","))"
        case .seedCard(let repoID, let title, _):
            "seedCard:\(repoID):\(title)"
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
        case .createLabels(let repoID, _, _), .seedCard(let repoID, _, _): repoID
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

    public func globalChecks(layout: RepoTreeLayout = .portfolio) async -> [CheckResult] {
        var results: [CheckResult] = []

        results.append(CheckResult(
            id: "env.loginShell",
            title: "Login shell environment",
            status: environment.capturedVia == "fallback" ? .warn : .pass,
            detail: environment.capturedVia == "fallback"
                ? "Could not read the login shell; using a built-in PATH. Tools may be missing."
                : "Captured via \(environment.capturedVia) — \(environment.searchPaths.count) PATH entries.",
            command: "/bin/zsh -lic 'env -0'"
        ))

        let locator = ToolLocator(environment: environment, overrides: .fromProcessEnvironment())
        for (tool, path) in [
            ("claude", config.claudePath), ("gh", config.ghPath), ("git", config.gitPath),
        ] {
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

        results.append(pluginCheck(
            id: "plugin.aiMigrationKit",
            title: "ai-migration-kit skills",
            plugin: "ai-migration-kit",
            required: ["create-issue", "implement-issue", "merge-pr"]
        ))
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

        let profilePath = ".claude/skills/repo-profile.md"
        let profileURL = URL(fileURLWithPath: repo.path).appendingPathComponent(profilePath)
        let profileExists = FileManager.default.fileExists(atPath: profileURL.path)
        results.append(CheckResult(
            id: "repo.profile", title: "Repo profile",
            status: profileExists ? .pass : .fail,
            detail: profileExists ? profilePath : "No \(profilePath); the skills read it at their preconditions step.",
            command: "cat \(profileURL.path)",
            fixHint: profileExists ? nil : "Run /ai-migration-kit:get-repo-profile in this repo."
        ))

        if profileExists {
            // An untracked profile does not exist inside a fresh worktree, and
            // implement-issue works from one.
            let tracked = await git.isTracked(path: profilePath, in: repo.path)
            results.append(CheckResult(
                id: "repo.profileCommitted", title: "Profile committed",
                status: tracked ? .pass : .warn,
                detail: tracked
                    ? "Tracked by git."
                    : "Untracked — it will be missing inside the worktrees implement-issue creates.",
                command: "git -C \(repo.path) ls-files --error-unmatch \(profilePath)",
                fixHint: tracked ? nil : "git add \(profilePath) && git commit"
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

        return results
    }

    /// Whether this repository has the labels Elliot's skills apply.
    ///
    /// **A warning, never a failure.** `isBlocking` treats any `.fail` as "cards
    /// cannot be dragged in this repository", and a missing `documentation`
    /// label must not freeze a board.
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
        required: [RequiredLabel] = LabelPolicy.default
    ) async -> CheckResult {
        let target = nameWithOwner ?? repo.nameWithOwner

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

        let missing = LabelPolicy.missing(required: required, present: present)
        guard !missing.isEmpty else {
            return CheckResult(
                id: "repo.labels", title: "Labels", status: .pass,
                detail: "All \(required.count) labels Elliot's skills apply are present.",
                command: "gh label list --repo \(target)"
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
                // For the case the button cannot serve: a repository that wants
                // its *own* taxonomy. Deciding one edits `repo-profile.md`, a
                // committed file, so it belongs in an issue and a pull request —
                // which is the pipeline the board already drives.
                .seedCard(
                    repoID: repo.id,
                    title: "Decide this repository's label taxonomy",
                    story: UserStory(
                        role: "maintainer of \(target)",
                        want: "a label taxonomy recorded in .claude/skills/repo-profile.md",
                        benefit: "create-issue labels issues the way this repository wants, "
                            + "instead of dropping labels it cannot find",
                        acceptanceCriteria: [
                            "The profile's Labels section names a real taxonomy, not a TODO.",
                            "Every label it names exists on the repository.",
                            "Elliot's Preflight labels check passes for \(target).",
                        ]
                    )
                ),
            ]
        )
    }

    /// Whether a repo's cards can be dragged at all.
    ///
    /// ⚠️ **This sentence was false from the day it was written until #249.**
    /// Nothing consulted it but four views: `evaluateMove`'s only repository
    /// term was `repoIsEnabled`, so a card in a repository this returned `true`
    /// for was drawn as blocked and dragged anyway, spawning `claude -p` at
    /// `bypassPermissions` inside a checkout Elliot had already diagnosed. It is
    /// true now because `AppModel.record` writes this verdict onto
    /// `Repo.preflight`, which `BoardService.proposeMove` reads.
    ///
    /// ⛔ **It still cannot answer for a repository nobody has swept.** On an
    /// empty array this is `false`, which reads as "fine" and is really "nobody
    /// looked" — the two-valued answer to a three-valued question that hid the
    /// gap for as long as it did. Callers that need to tell those apart use
    /// `PreflightState`, where not looking is its own case; this stays a `Bool`
    /// because its callers hold results they have just computed.
    public static func isBlocking(_ results: [CheckResult]) -> Bool {
        results.contains { $0.status == .fail }
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
    public func apply(
        _ fix: CheckFix, repo: Repo, board: BoardService
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

        case .seedCard(_, let title, let story):
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
