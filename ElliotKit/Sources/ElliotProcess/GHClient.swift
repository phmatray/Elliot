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

    /// The fields `issues(repo:limit:)` asks for.
    ///
    /// Named rather than inlined so `Fixtures/gh/issues.json` can be held
    /// against it: a captured payload is only a contract while the capture and
    /// the request name the same fields, and nothing else would notice them
    /// drifting apart — a field the client stops asking for arrives as `nil`,
    /// which decodes perfectly.
    static let issueListFields = "number,title,body,url,state,createdAt"

    /// Every issue of a repo. `body` is requested because an imported card's
    /// text is the issue's text.
    public func issues(repo: String, limit: Int = 100) async throws -> [GHIssue] {
        try await json(
            [GHIssue].self,
            arguments: ["issue", "list", "--repo", repo, "--state", "all",
                        "--limit", String(limit), "--json", Self.issueListFields]
        )
    }

    // MARK: - Pull requests

    /// The fields `pullRequests(repo:limit:)` asks for — see `issueListFields`.
    static let pullRequestListFields =
        "number,url,title,body,headRefName,isDraft,state,createdAt,mergedAt,headRefOid"

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
                        "--json", Self.pullRequestListFields]
        )
    }

    /// The fields `mergeStatus(repo:number:)` asks for — see `issueListFields`.
    ///
    /// `Fixtures/gh/pr-view-*.json` are verbatim captures taken with exactly this
    /// set, and `GHMergeStatusTests` holds the two against each other: a field
    /// dropped here arrives as `nil`, which decodes perfectly and would be caught
    /// by nothing else.
    static let mergeStatusFields =
        "state,mergedAt,mergeCommit,url,statusCheckRollup,mergeable,mergeStateStatus,"
        + "reviewDecision,headRefOid"

    public func mergeStatus(repo: String, number: Int) async throws -> GHMergeStatus {
        try await json(
            GHMergeStatus.self,
            arguments: ["pr", "view", String(number), "--repo", repo,
                        "--json", Self.mergeStatusFields]
        )
    }

    // MARK: - Labels

    /// One row of `gh label list --json name`. Only the name: colour and
    /// description belong to whoever *creates* a label, and `LabelPolicy`
    /// carries those. Decoding fields nobody reads would just be two more ways
    /// for the decode to fail.
    private struct GHLabelName: Decodable { let name: String }

    /// Every label a repository has, by name.
    ///
    /// **Throws rather than answering `[]` when `gh` fails**, and the difference
    /// is the whole point of the check that calls this: `[]` is a *finding* —
    /// "this repository has no labels" — so returning it for an unreachable
    /// repository would report every required label as missing and offer a
    /// button to create them, against a repository nobody could reach.
    public func labels(repo: String, limit: Int = 200) async throws -> [String] {
        try await json(
            [GHLabelName].self,
            arguments: ["label", "list", "--repo", repo,
                        "--limit", String(limit), "--json", "name"]
        ).map(\.name)
    }

    /// Creates one label. **Returns whether it actually created it.**
    ///
    /// A name that already exists is **success**, not an error: `gh label
    /// create` exits non-zero for it, but the caller wanted a repository that
    /// has this label and that is the repository they have — and between the
    /// check and the button a second Elliot window, or a hand-created label, can
    /// make it true. Turning that into a red banner would report a failure that
    /// is not one.
    ///
    /// It is nevertheless **distinguished from creating**, because `labels()`
    /// reads one page: a repository past that limit can have a label the check
    /// reported missing, and reporting "created" for it would put a sentence
    /// beside a row that still says it is missing — two claims about one label,
    /// in one panel, one of them false.
    ///
    /// The tolerance is deliberately narrow: it keys on `gh`'s own words, so a
    /// refusal for permissions or a repository that does not exist still throws.
    /// Swallowing those would report labels as created that are not.
    @discardableResult
    public func createLabel(_ label: RequiredLabel, repo: String) async throws -> Bool {
        do {
            _ = try await ProcessRunner.check(
                executable: config.ghPath,
                arguments: ["label", "create", label.name,
                            "--repo", repo,
                            "--color", label.color,
                            "--description", label.description],
                environment: config.environment,
                timeout: .seconds(30)
            )
            return true
        } catch let error as ProcessError {
            guard Self.isAlreadyExists(error) else { throw error }
            return false
        }
    }

    /// Whether a failed `label create` failed only because the label is there.
    ///
    /// Matched on the message rather than the exit code, because `gh` uses the
    /// same non-zero code for every failure. Internal so a test can state the
    /// wording it depends on instead of discovering it through two layers.
    static func isAlreadyExists(_ error: ProcessError) -> Bool {
        "\(error)".lowercased().contains("already exists")
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

    /// The working tree's changes, exactly as `git status --porcelain` prints
    /// them. Compared before and after an analysis: Elliot cannot stop a run
    /// writing to your repository, so it notices instead.
    public func porcelainStatus(cwd: String) async -> String {
        (try? await run(["status", "--porcelain"], cwd: cwd)) ?? ""
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

    /// Clones through `gh`, so authentication and the ssh/https choice stay the
    /// user's rather than something Elliot guesses from a URL. Refuses an
    /// existing path: cloning into a non-empty directory has no sensible meaning
    /// here, and nothing in Elliot deletes a clone.
    public func clone(nameWithOwner: String, into path: String) async throws {
        guard !FileManager.default.fileExists(atPath: path) else {
            throw ProcessError.failed(
                command: "gh repo clone", exitCode: 1,
                stderr: "\(path) already exists.")
        }
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try await ProcessRunner.check(
            executable: config.ghPath, arguments: ["repo", "clone", nameWithOwner, path],
            environment: config.environment, timeout: .seconds(600))
    }

    /// Updates the remote-tracking refs and nothing else. Separate from
    /// `aheadBehind` on purpose: a query that silently reaches the network is a
    /// query you cannot reason about in a loop over 221 clones.
    public func fetch(cwd: String) async throws {
        _ = try await run(["fetch", "--quiet", "--prune"], cwd: cwd)
    }

    /// Commits on each side of the upstream, or nil when there is no upstream.
    ///
    /// Reads `@{u}`, a **local** ref: without a preceding `fetch` this answers
    /// `behind: 0` for a clone that is in fact behind. That is not a hypothetical
    /// — it is how 200 of 244 clones once measured as current while they were not.
    public func aheadBehind(cwd: String) async -> (ahead: Int, behind: Int)? {
        guard
            let output = try? await run(
                ["rev-list", "--left-right", "--count", "@{u}...HEAD"], cwd: cwd)
        else { return nil }
        let parts = output.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        // `--left-right` counts the left side first, and the left side is `@{u}`:
        // what upstream has and we do not is how far *behind* we are.
        return (ahead: parts[1], behind: parts[0])
    }

    /// True when HEAD points at a commit rather than a branch — which means
    /// there is no upstream to compare against, and nothing to fast-forward.
    public func isDetached(cwd: String) async -> Bool {
        (try? await run(["symbolic-ref", "-q", "HEAD"], cwd: cwd)) == nil
    }

    /// Fast-forward or nothing.
    ///
    /// `--ff-only` is the whole safety property: a dirty, ahead or diverged clone
    /// means a human has work there, and Elliot's answer is to say so, not to
    /// merge. Never `--rebase`, never `--autostash`, never a `--force` of any
    /// kind — this is the only verb in Elliot that writes inside a working tree
    /// the user may be mid-edit.
    public func pullFastForward(cwd: String) async throws {
        _ = try await run(["pull", "--ff-only"], cwd: cwd)
    }

    /// Moves a clone into its expected folder. Refuses an occupied destination:
    /// there is no merge of two working trees, and nothing here deletes.
    public func relocate(from source: String, to destination: String) throws {
        guard !FileManager.default.fileExists(atPath: destination) else {
            throw ProcessError.failed(
                command: "mv", exitCode: 1,
                stderr: "\(destination) already exists.")
        }
        try FileManager.default.createDirectory(
            atPath: (destination as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: source, toPath: destination)
    }
}
