import Foundation

/// The environment a command would see in the user's own terminal.
///
/// An app launched from the Finder inherits `PATH=/usr/bin:/bin:/usr/sbin:/sbin`
/// — which contains neither `claude` (`~/.local/bin`) nor `gh`
/// (`/opt/homebrew/bin`). Finding those two binaries is not enough either:
/// `claude` itself shells out to `git`, `gh` and `node`, so the whole
/// environment has to be reconstructed and handed to every child.
///
/// Running the app from Xcode hides this entirely — Xcode passes its own
/// inherited shell environment through. The bug only shows up when the `.app`
/// is double-clicked.
public struct LoginShellEnvironment: Sendable {
    public let variables: [String: String]
    public let capturedVia: String

    /// Variables that describe the *capturing* shell rather than the user's
    /// configuration, and would mislead a child process.
    private static let excluded: Set<String> = ["_", "SHLVL", "PWD", "OLDPWD", "ZSH_EXECUTION_STRING"]

    /// Where the tools live when the shell cannot be interrogated at all.
    static let fallbackPATH = [
        "\(NSHomeDirectory())/.local/bin",
        "\(NSHomeDirectory())/.claude/local",
        "\(NSHomeDirectory())/.bun/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ].joined(separator: ":")

    public init(variables: [String: String], capturedVia: String) {
        self.variables = variables
        self.capturedVia = capturedVia
    }

    public var path: String { variables["PATH"] ?? Self.fallbackPATH }

    public var searchPaths: [String] {
        path.split(separator: ":").map(String.init)
    }

    /// Interrogates the login shell once.
    ///
    /// `-l` picks up `.zprofile`, `-i` picks up the `PATH` edits most people
    /// actually write in `.zshrc`; both are needed. `env -0` is used rather
    /// than `env` because values legitimately contain newlines.
    public static func capture(shell: String = "/bin/zsh", timeout: Duration = .seconds(5)) async -> LoginShellEnvironment {
        for flags in ["-lic", "-lc"] {
            if let result = try? await ProcessRunner.run(
                executable: shell,
                arguments: [flags, "env -0"],
                environment: ProcessInfo.processInfo.environment,
                timeout: timeout
            ), result.exitCode == 0, !result.stdoutData.isEmpty {
                let parsed = parse(result.stdoutData)
                if parsed["PATH"] != nil {
                    return LoginShellEnvironment(variables: parsed, capturedVia: "\(shell) \(flags)")
                }
            }
        }

        // Last resort: the process environment with a PATH that at least covers
        // the usual install locations.
        var variables = ProcessInfo.processInfo.environment
        variables["PATH"] = fallbackPATH
        return LoginShellEnvironment(variables: variables, capturedVia: "fallback")
    }

    static func parse(_ data: Data) -> [String: String] {
        var result: [String: String] = [:]
        for entry in data.split(separator: 0x00) {
            guard let text = String(data: Data(entry), encoding: .utf8),
                  let separator = text.firstIndex(of: "=")
            else { continue }
            let key = String(text[text.startIndex..<separator])
            guard !key.isEmpty, !excluded.contains(key) else { continue }
            result[key] = String(text[text.index(after: separator)...])
        }
        return result
    }

    /// The environment to hand a spawned tool: the captured one, with the
    /// working directory corrected and Elliot identified to the CLI.
    public func childEnvironment(cwd: String) -> [String: String] {
        var env = variables
        env["PWD"] = cwd
        env["CLAUDE_CODE_ENTRYPOINT"] = "elliot-swift"
        return env
    }
}
