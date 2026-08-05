import ElliotModel
import Foundation

/// Typed wrappers over `gh … --json`.
///
/// Every verifier goes through here rather than reading the agent's prose,
/// because the prose is free text that varies between runs while these payloads
/// are a contract.
public struct GHClient: Sendable {
    private let config: ToolConfig

    public init(config: ToolConfig) {
        self.config = config
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func json<T: Decodable>(
        _ type: T.Type,
        arguments: [String],
        cwd: String? = nil,
        timeout: Duration = .seconds(60)
    ) async throws -> T {
        let result = try await ProcessRunner.check(
            executable: config.ghPath,
            arguments: arguments,
            cwd: cwd,
            environment: config.environment,
            timeout: timeout
        )
        return try Self.decoder.decode(T.self, from: result.stdoutData)
    }

    // MARK: - Auth and repo identity

    public func isAuthenticated() async -> Bool {
        let result = try? await ProcessRunner.run(
            executable: config.ghPath,
            arguments: ["auth", "status"],
            environment: config.environment,
            timeout: .seconds(20)
        )
        return result?.succeeded ?? false
    }

    public func login() async throws -> String {
        let result = try await ProcessRunner.check(
            executable: config.ghPath,
            arguments: ["api", "user", "--jq", ".login"],
            environment: config.environment,
            timeout: .seconds(20)
        )
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func repoInfo(cwd: String) async throws -> GHRepoInfo {
        try await json(
            GHRepoInfo.self,
            arguments: ["repo", "view", "--json", "nameWithOwner,defaultBranchRef"],
            cwd: cwd
        )
    }

    /// Every repository of an account, archived and forks included.
    ///
    /// They are listed rather than filtered so a row can say *why* nothing is
    /// offered for them; a repository dropped from the listing is
    /// indistinguishable from one that is fine.
    public func repos(owner: String, limit: Int = 1000) async throws -> [GHRepoSummary] {
        try await json(
            [GHRepoSummary].self,
            arguments: [
                "repo", "list", owner, "--limit", String(limit),
                "--json", "nameWithOwner,visibility,defaultBranchRef,isFork,isArchived,url",
            ],
            timeout: .seconds(120)
        )
    }

    // MARK: - Issues

    public func issue(repo: String, number: Int) async throws -> GHIssue {
        try await json(
            GHIssue.self,
            arguments: ["issue", "view", String(number), "--repo", repo,
                        "--json", "number,title,url,state,createdAt"]
        )
    }

    public func issues(repo: String, limit: Int = 100) async throws -> [GHIssue] {
        try await json(
            [GHIssue].self,
            arguments: ["issue", "list", "--repo", repo, "--state", "all",
                        "--limit", String(limit), "--json", "number,title,url,state,createdAt"]
        )
    }

    // MARK: - Pull requests

    /// Every PR of a repo, recent first.
    ///
    /// Listing and matching is the only workable approach: the branch a run
    /// creates is `feat/<issue>-<slug>` where the slug is written by the agent
    /// from the issue title, so `--head` cannot be constructed in advance.
    public func pullRequests(repo: String, limit: Int = 50) async throws -> [GHPullRequest] {
        try await json(
            [GHPullRequest].self,
            arguments: ["pr", "list", "--repo", repo, "--state", "all",
                        "--limit", String(limit),
                        "--json", "number,url,title,body,headRefName,isDraft,state,createdAt,mergedAt"]
        )
    }

    public func mergeStatus(repo: String, number: Int) async throws -> GHMergeStatus {
        try await json(
            GHMergeStatus.self,
            arguments: ["pr", "view", String(number), "--repo", repo,
                        "--json", "state,mergedAt,mergeCommit,url,statusCheckRollup"]
        )
    }
}

/// The few `git` questions Elliot needs answered.
public struct GitClient: Sendable {
    private let config: ToolConfig

    public init(config: ToolConfig) {
        self.config = config
    }

    private func run(_ arguments: [String], cwd: String) async throws -> String {
        let result = try await ProcessRunner.check(
            executable: config.gitPath,
            arguments: arguments,
            cwd: cwd,
            environment: config.environment,
            timeout: .seconds(30)
        )
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func topLevel(cwd: String) async throws -> String {
        try await run(["rev-parse", "--show-toplevel"], cwd: cwd)
    }

    /// True when `path` is the main checkout rather than a linked worktree.
    ///
    /// `merge-pr` removes the PR's worktree and cannot do that from inside it,
    /// so a repo registered as a worktree would fail at the last step.
    public func isMainCheckout(path: String) async -> Bool {
        guard let commonDir = try? await run(["rev-parse", "--git-common-dir"], cwd: path),
              let top = try? await topLevel(cwd: path)
        else { return false }
        let absolute = commonDir.hasPrefix("/")
            ? commonDir
            : (top as NSString).appendingPathComponent(commonDir)
        return URL(fileURLWithPath: absolute).standardizedFileURL.path
            .hasPrefix(URL(fileURLWithPath: top).standardizedFileURL.path)
    }

    public func isClean(cwd: String) async -> Bool {
        let status = try? await run(["status", "--porcelain"], cwd: cwd)
        return (status ?? "dirty").isEmpty
    }

    /// Worktrees, discovered rather than assumed — the location comes from the
    /// repo's own conventions, not from a path Elliot can hardcode.
    public func worktreePaths(cwd: String) async -> [String] {
        guard let output = try? await run(["worktree", "list", "--porcelain"], cwd: cwd) else { return [] }
        return output
            .split(separator: "\n")
            .filter { $0.hasPrefix("worktree ") }
            .map { String($0.dropFirst("worktree ".count)) }
    }

    public func isTracked(path: String, in cwd: String) async -> Bool {
        (try? await run(["ls-files", "--error-unmatch", path], cwd: cwd)) != nil
    }
}
