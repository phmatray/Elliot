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
        let git = await locator.locate("git")
        #expect(git != nil)
        #expect(git?.version?.contains("git version") == true)
    }
}
