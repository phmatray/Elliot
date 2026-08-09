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

/// Which binary a tool resolved to, or why it did not.
///
/// ⛔ **Three cases, because "not found" and "you told me which one and it
/// cannot be run" demand different next actions** — put the tool on your PATH,
/// versus fix the variable you set. Collapsing them would send someone who
/// mistyped a path off to install software they already have.
public enum ToolResolution: Sendable, Hashable {
    case found(LocatedTool)

    /// An override variable names something that is not an executable file.
    ///
    /// ⛔ **Deliberately not a fall-through to `PATH`.** Falling through is what
    /// `find` used to do, and it is this repository's most-catalogued failure
    /// shape: a mechanism that silently substitutes different behaviour instead
    /// of erroring. "I told it which `gh` to use and it quietly ran a different
    /// one" is worse than any refusal.
    case overrideUnusable(variable: String, value: String)

    case notFound

    public var tool: LocatedTool? {
        if case .found(let tool) = self { return tool }
        return nil
    }
}

/// Launch-time answers to "which `claude`/`gh`/`git` should Elliot run".
///
/// The one place that reads `ProcessInfo`, mirroring `StoreLocation`'s handling
/// of `ELLIOT_HOME` — and it is separable from that read, so tests inject a
/// dictionary and never mutate the process environment. That is what keeps the
/// suites parallel-safe.
public struct ToolOverrides: Sendable, Hashable {
    private let byTool: [String: String]

    public init(_ byTool: [String: String] = [:]) { self.byTool = byTool }

    public subscript(tool: String) -> String? { byTool[tool] }

    public var isEmpty: Bool { byTool.isEmpty }

    /// `ELLIOT_GH_PATH` for `gh`, and so on.
    public static func variableName(for tool: String) -> String {
        "ELLIOT_\(tool.uppercased())_PATH"
    }

    /// Reads every `ELLIOT_<TOOL>_PATH` out of `environment`.
    ///
    /// Pattern-matched rather than looked up from a list of known tools, so a
    /// fourth tool needs **no code at all** — which is the difference between a
    /// mechanism and three special cases. A variable naming a tool nothing ever
    /// asks for is inert, which is the right cost for that.
    ///
    /// `ELLIOT_HOME` does not match, and an empty value is ignored: `VAR=` is
    /// how a shell unsets something in practice, and reading it as "override to
    /// the empty path" would turn a clearing gesture into a refusal.
    public static func from(environment: [String: String]) -> ToolOverrides {
        var found: [String: String] = [:]
        for (key, value) in environment
        where key.hasPrefix("ELLIOT_") && key.hasSuffix("_PATH") && !value.isEmpty {
            let middle = key.dropFirst("ELLIOT_".count).dropLast("_PATH".count)
            guard !middle.isEmpty else { continue }
            found[middle.lowercased()] = value
        }
        return ToolOverrides(found)
    }

    /// The single `ProcessInfo` read. Kept to one line so the logic above stays
    /// testable without touching the process the tests run in.
    public static func fromProcessEnvironment() -> ToolOverrides {
        from(environment: ProcessInfo.processInfo.environment)
    }
}

/// Finds `claude`, `gh` and `git` for an app that cannot rely on `PATH`.
public struct ToolLocator: Sendable {
    private let environment: LoginShellEnvironment
    private let overrides: ToolOverrides

    public init(environment: LoginShellEnvironment, overrides: ToolOverrides = ToolOverrides()) {
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

    public func locate(_ tool: String, versionArgument: String? = "--version") async -> ToolResolution {
        // Ahead of every other source, and it refuses rather than falls through:
        // an override that names an unusable path is a mistake to show, not a
        // reason to run something else (#238).
        if let override = overrides[tool] {
            guard FileManager.default.isExecutableFile(atPath: override) else {
                return .overrideUnusable(
                    variable: ToolOverrides.variableName(for: tool), value: override)
            }
        }
        guard let (path, via) = await find(tool) else { return .notFound }

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

        return .found(
            LocatedTool(
                name: tool, path: path, resolvedPath: resolved, version: version, foundVia: via))
    }

    private func find(_ tool: String) async -> (path: String, via: String)? {
        // The usability check is `locate`'s, not this function's — here it could
        // only be expressed as "fall through", which is the defect.
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
