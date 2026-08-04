import ElliotModel
import ElliotProcess
import ElliotStore
import Foundation

public enum CheckStatus: String, Sendable, Hashable {
    case pass, warn, fail
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

    public func globalChecks() async -> [CheckResult] {
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

        let locator = ToolLocator(environment: environment)
        for (tool, path) in [
            ("claude", config.claudePath), ("gh", config.ghPath), ("git", config.gitPath),
        ] {
            let located = await locator.locate(tool)
            let found = FileManager.default.isExecutableFile(atPath: path)
            results.append(CheckResult(
                id: "tool.\(tool)",
                title: tool,
                status: found ? .pass : .fail,
                detail: found
                    ? [located?.resolvedPath ?? path, located?.version].compactMap { $0 }.joined(separator: " — ")
                    : "Not found. An app launched from the Finder does not inherit your shell PATH.",
                command: "command -v \(tool)",
                fixHint: found ? nil : "Point Elliot at the binary in Settings."
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

        return results
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

        return results
    }

    /// Whether a repo's cards can be dragged at all.
    public static func isBlocking(_ results: [CheckResult]) -> Bool {
        results.contains { $0.status == .fail }
    }
}
