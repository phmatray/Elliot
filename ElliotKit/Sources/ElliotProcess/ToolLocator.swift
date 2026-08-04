import Foundation

public struct LocatedTool: Sendable, Hashable {
    public var name: String
    public var path: String
    /// The symlink target, when the path is one. `claude` is normally
    /// `~/.local/bin/claude → ~/.local/share/claude/versions/<n>`, and showing
    /// the version that is actually about to run saves a debugging round.
    public var resolvedPath: String
    public var version: String?
    public var foundVia: String
}

/// Finds `claude`, `gh` and `git` for an app that cannot rely on `PATH`.
public struct ToolLocator: Sendable {
    private let environment: LoginShellEnvironment
    private let overrides: [String: String]

    public init(environment: LoginShellEnvironment, overrides: [String: String] = [:]) {
        self.environment = environment
        self.overrides = overrides
    }

    /// Extra places to look when the captured `PATH` comes up empty.
    private static func candidates(for tool: String) -> [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/.local/bin/\(tool)",
            "\(home)/.claude/local/\(tool)",
            "\(home)/.bun/bin/\(tool)",
            "/opt/homebrew/bin/\(tool)",
            "/usr/local/bin/\(tool)",
            "/usr/bin/\(tool)",
        ]
    }

    public func locate(_ tool: String, versionArgument: String? = "--version") async -> LocatedTool? {
        guard let (path, via) = await find(tool) else { return nil }

        let resolved = (try? FileManager.default.destinationOfSymbolicLink(atPath: path))
            .map { $0.hasPrefix("/") ? $0 : URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent($0).standardizedFileURL.path }
            ?? path

        var version: String?
        if let versionArgument,
           let result = try? await ProcessRunner.run(
               executable: path,
               arguments: [versionArgument],
               environment: environment.variables,
               timeout: .seconds(10)
           ), result.succeeded {
            version = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").first.map(String.init)
        }

        return LocatedTool(name: tool, path: path, resolvedPath: resolved, version: version, foundVia: via)
    }

    private func find(_ tool: String) async -> (path: String, via: String)? {
        if let override = overrides[tool], FileManager.default.isExecutableFile(atPath: override) {
            return (override, "user override")
        }
        for directory in environment.searchPaths {
            let path = (directory as NSString).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: path) {
                return (path, "PATH (\(environment.capturedVia))")
            }
        }
        for path in Self.candidates(for: tool) where FileManager.default.isExecutableFile(atPath: path) {
            return (path, "known install location")
        }
        // Last resort: ask the shell itself.
        if let result = try? await ProcessRunner.run(
            executable: "/bin/zsh",
            arguments: ["-lic", "command -v \(tool)"],
            environment: environment.variables,
            timeout: .seconds(5)
        ), result.succeeded {
            let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return (path, "command -v")
            }
        }
        return nil
    }
}

/// The resolved binaries and environment every spawned command uses.
///
/// Injected by construction rather than read from a global, so tests can point
/// at fake tools and still run in parallel.
public struct ToolConfig: Sendable {
    public var claudePath: String
    public var ghPath: String
    public var gitPath: String
    public var environment: [String: String]

    public init(claudePath: String, ghPath: String, gitPath: String, environment: [String: String]) {
        self.claudePath = claudePath
        self.ghPath = ghPath
        self.gitPath = gitPath
        self.environment = environment
    }
}
