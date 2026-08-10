import ElliotModel
import Foundation
import Testing

@testable import ElliotProcess

private func lines(_ datas: [Data]) -> [String] {
    datas.map { String(decoding: $0, as: UTF8.self) }
}

@Suite("Line buffer")
struct LineBufferTests {

    @Test("Whole lines in one chunk come straight out")
    func wholeLines() {
        var buffer = LineBuffer()
        #expect(lines(buffer.append(Data("a\nb\nc\n".utf8))) == ["a", "b", "c"])
        #expect(buffer.flush() == nil)
    }

    @Test("A line split across three reads is reassembled")
    func splitLine() {
        var buffer = LineBuffer()
        #expect(buffer.append(Data(#"{"type":"res"#.utf8)).isEmpty)
        #expect(buffer.append(Data(#"ult","is_err"#.utf8)).isEmpty)
        let out = buffer.append(Data("or\":false}\n".utf8))
        #expect(lines(out) == [#"{"type":"result","is_error":false}"#])
    }

    @Test("A chunk holding the tail of one line and the head of the next")
    func straddlingChunk() {
        var buffer = LineBuffer()
        _ = buffer.append(Data("first".utf8))
        #expect(lines(buffer.append(Data("-half\nsecond".utf8))) == ["first-half"])
        #expect(lines(buffer.append(Data("-half\n".utf8))) == ["second-half"])
    }

    @Test("The last line survives when the process ends without a newline")
    func flushTail() {
        var buffer = LineBuffer()
        #expect(lines(buffer.append(Data("done\nlast".utf8))) == ["done"])
        let tail = buffer.flush()
        #expect(String(decoding: tail!, as: UTF8.self) == "last")
        #expect(buffer.flush() == nil)
    }

    @Test("CRLF is tolerated")
    func carriageReturns() {
        var buffer = LineBuffer()
        #expect(lines(buffer.append(Data("a\r\nb\r\n".utf8))) == ["a", "b"])
    }

    @Test("Empty lines are preserved rather than swallowed")
    func emptyLines() {
        var buffer = LineBuffer()
        #expect(lines(buffer.append(Data("a\n\nb\n".utf8))) == ["a", "", "b"])
    }

    @Test("A very large single line is reassembled intact")
    func largeLine() {
        var buffer = LineBuffer()
        let payload = String(repeating: "x", count: 700_000)
        var emitted: [Data] = []
        // Feed it in 64 KB chunks, the way a pipe would.
        var remaining = Data((payload + "\n").utf8)
        while !remaining.isEmpty {
            let chunk = remaining.prefix(64 * 1024)
            remaining = remaining.dropFirst(chunk.count)
            emitted += buffer.append(Data(chunk))
        }
        #expect(emitted.count == 1)
        #expect(emitted[0].count == 700_000)
    }

    @Test("A runaway line is truncated instead of exhausting memory")
    func oversizedLineIsCapped() {
        var buffer = LineBuffer(limit: 1024)
        for _ in 0..<10 {
            _ = buffer.append(Data(String(repeating: "y", count: 512).utf8))
        }
        #expect(buffer.truncatedLineCount > 0)
        let tail = buffer.flush()
        #expect((tail?.count ?? 0) <= 1024)
    }

    @Test("No input produces no lines")
    func empty() {
        var buffer = LineBuffer()
        #expect(buffer.append(Data()).isEmpty)
        #expect(buffer.flush() == nil)
    }
}

@Suite("Login shell environment")
struct LoginShellEnvironmentTests {

    @Test("NUL-separated env output is parsed, including multi-line values")
    func parsing() {
        let raw = "PATH=/usr/bin:/bin\0HOME=/Users/philippe\0MULTI=line one\nline two\0"
        let parsed = LoginShellEnvironment.parse(Data(raw.utf8))
        #expect(parsed["PATH"] == "/usr/bin:/bin")
        #expect(parsed["HOME"] == "/Users/philippe")
        #expect(parsed["MULTI"] == "line one\nline two")
    }

    @Test("Variables describing the capturing shell are dropped")
    func excludesShellNoise() {
        let raw = "PATH=/bin\0_=/usr/bin/env\0SHLVL=1\0PWD=/tmp\0OLDPWD=/\0"
        let parsed = LoginShellEnvironment.parse(Data(raw.utf8))
        #expect(parsed.keys.sorted() == ["PATH"])
    }

    @Test("An empty value is kept, not treated as absent")
    func emptyValue() {
        let parsed = LoginShellEnvironment.parse(Data("EMPTY=\0PATH=/bin\0".utf8))
        #expect(parsed["EMPTY"] == "")
    }

    @Test("A child gets the working directory and Elliot's entrypoint tag")
    func childEnvironment() {
        let env = LoginShellEnvironment(variables: ["PATH": "/bin"], capturedVia: "test")
        let child = env.childEnvironment(cwd: "/repo")
        #expect(child["PWD"] == "/repo")
        #expect(child["CLAUDE_CODE_ENTRYPOINT"] == "elliot-swift")
        #expect(child["PATH"] == "/bin")
    }

    @Test("Capturing the real login shell finds a usable PATH")
    func realCapture() async {
        let env = await LoginShellEnvironment.capture()
        #expect(!env.searchPaths.isEmpty)
        #expect(env.path.contains("/bin"))
    }

    @Test("The real toolchain is locatable without relying on PATH inheritance")
    func locateRealTools() async {
        // This is the check that would have caught the Finder-launch bug: the
        // environment is captured, not inherited.
        let env = await LoginShellEnvironment.capture()
        let locator = ToolLocator(environment: env)
        let git = await locator.locate("git").tool
        #expect(git != nil)
        #expect(git?.version?.contains("git version") == true)
    }

    // MARK: - Tool overrides (#238)

    /// The variable is derived from the tool name, so a fourth tool needs no
    /// code — which is the difference between a mechanism and three special
    /// cases.
    @Test("An override variable is named after its tool")
    func variableNameIsDerived() {
        #expect(ToolOverrides.variableName(for: "gh") == "ELLIOT_GH_PATH")
        #expect(ToolOverrides.variableName(for: "claude") == "ELLIOT_CLAUDE_PATH")
        #expect(ToolOverrides.variableName(for: "git") == "ELLIOT_GIT_PATH")
    }

    /// ⚠️ Parsed from an injected dictionary, never from the process — that is
    /// what keeps these suites parallel-safe, and it is why `from(environment:)`
    /// is separate from the one line that reads `ProcessInfo`.
    @Test("Only ELLIOT_<TOOL>_PATH is read, and an empty value is not an override")
    func parsingIsPatternMatched() {
        let overrides = ToolOverrides.from(environment: [
            "ELLIOT_GH_PATH": "/tmp/shim/gh",
            "ELLIOT_HOME": "/tmp/elliot-check",   // not a tool path
            "PATH": "/usr/bin",
            "ELLIOT_GIT_PATH": "",                // `VAR=` is how a shell clears one
            "ELLIOT__PATH": "/nope",              // no tool named
        ])
        #expect(overrides["gh"] == "/tmp/shim/gh")
        #expect(overrides["home"] == nil)
        #expect(overrides["git"] == nil)
        #expect(overrides[""] == nil)
    }

    @Test("No variables set means no overrides at all")
    func absentOverridesAreEmpty() {
        #expect(ToolOverrides.from(environment: ["PATH": "/usr/bin"]).isEmpty)
    }

    @Test("An override that names an executable is honoured, and says so")
    func anOverrideIsHonoured() async {
        let env = await LoginShellEnvironment.capture()
        // `/bin/echo` rather than a fixture: it exists on every macOS, it is
        // executable, and it is definitively *not* what resolving "gh" would
        // otherwise find — so a pass here cannot be the ordinary path in
        // disguise.
        let locator = ToolLocator(
            environment: env, overrides: ToolOverrides(["gh": "/bin/echo"]))

        let resolution = await locator.locate("gh", versionArgument: nil)

        #expect(resolution.tool?.path == "/bin/echo")
        #expect(resolution.tool?.foundVia == "user override")
    }

    /// ⛔ The case the seam existed for and never covered: `find` fell through to
    /// `PATH` when the override was set but unusable, so "I told it which gh to
    /// use and it quietly ran a different one" was the design.
    @Test("An override that cannot be run refuses by name instead of falling back to PATH")
    func anUnusableOverrideRefuses() async {
        let env = await LoginShellEnvironment.capture()
        let locator = ToolLocator(
            environment: env, overrides: ToolOverrides(["gh": "/tmp/definitely-not-here-9f3a"]))

        let resolution = await locator.locate("gh", versionArgument: nil)

        #expect(
            resolution == .overrideUnusable(
                variable: "ELLIOT_GH_PATH", value: "/tmp/definitely-not-here-9f3a"),
            """
            resolved to \(resolution) — falling through to PATH here runs a binary the reader did \
            not name, which is the silent substitution this refusal exists to prevent
            """
        )
        #expect(resolution.tool == nil, "an unusable override must not yield a tool at all")
    }

    /// AC 5: with nothing set, resolution is byte-for-byte what it was.
    @Test("With no override, a tool resolves exactly as it did before")
    func noOverrideChangesNothing() async {
        let env = await LoginShellEnvironment.capture()
        let plain = await ToolLocator(environment: env).locate("git", versionArgument: nil)
        let empty = await ToolLocator(environment: env, overrides: ToolOverrides())
            .locate("git", versionArgument: nil)

        #expect(plain == empty)
        #expect(plain.tool?.foundVia != "user override")
    }
}
