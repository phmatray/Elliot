//
//  ProcessManager.swift
//  ACP
//
//  Manages subprocess lifecycle, I/O pipes, and message serialization
//

#if os(macOS)
import Foundation
import Darwin
import os.log
import ACPModel

actor ACPProcessManager {
    // MARK: - Properties

    private var process: Process?
    private var processGroupId: pid_t?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    private var readBuffer: Data = Data()
    private var largeBufferDumpCount: Int = 0
    private var lastLargeBufferDumpSize: Int = 0

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let logger: Logger

    private static let largeBufferWarningThreshold = 200000
    private static let largeBufferDumpMinGrowth = 8192
    private static let maxLargeBufferDumps = 3

    private var onDataReceived: ((Data) async -> Void)?
    private var onTermination: ((Int32) async -> Void)?

    private enum OutputChunk: Sendable {
        case stdout(Data)
        case stderr(Data)
    }

    private var outputContinuation: AsyncStream<OutputChunk>.Continuation?
    private var outputConsumerTask: Task<Void, Never>?
    private var stderrLineContinuation: AsyncStream<String>.Continuation?
    private var stderrLineStream: AsyncStream<String>?
    private var stderrBuffer = Data()

    // MARK: - Initialization

    init(encoder: JSONEncoder, decoder: JSONDecoder) {
        self.encoder = encoder
        self.decoder = decoder
        self.logger = Logger.forCategory("ACPProcessManager")
    }

    // MARK: - Process Lifecycle

    func launch(
        agentPath: String, arguments: [String] = [], workingDirectory: String? = nil,
        environment customEnvironment: [String: String]? = nil
    ) throws {
        guard process == nil else {
            throw ClientError.invalidResponse
        }

        let proc = Process()

        let resolvedPath =
            (try? FileManager.default.destinationOfSymbolicLink(atPath: agentPath)) ?? agentPath
        let actualPath =
            resolvedPath.hasPrefix("/")
            ? resolvedPath
            : ((agentPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent(
                resolvedPath)

        let isNodeScript: Bool = {
            guard let handle = FileHandle(forReadingAtPath: actualPath) else { return false }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 64),
                let firstLine = String(data: data, encoding: .utf8)
            else { return false }
            return firstLine.hasPrefix("#!/usr/bin/env node")
        }()

        if isNodeScript {
            let searchPaths = [
                (agentPath as NSString).deletingLastPathComponent,
                (actualPath as NSString).deletingLastPathComponent,
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
            ]

            var foundNode: String?
            for searchPath in searchPaths {
                let nodePath = (searchPath as NSString).appendingPathComponent("node")
                if FileManager.default.fileExists(atPath: nodePath) {
                    foundNode = nodePath
                    break
                }
            }

            if let nodePath = foundNode {
                proc.executableURL = URL(fileURLWithPath: nodePath)
                proc.arguments = [actualPath] + arguments
            } else {
                proc.executableURL = URL(fileURLWithPath: agentPath)
                proc.arguments = arguments
            }
        } else {
            proc.executableURL = URL(fileURLWithPath: agentPath)
            proc.arguments = arguments
        }

        var environment = ShellEnvironment.loadUserShellEnvironment()

        // Merge custom environment variables (override shell env)
        if let customEnvironment {
            for (key, value) in customEnvironment {
                environment[key] = value
            }
        }

        if let workingDirectory, !workingDirectory.isEmpty {
            environment["PWD"] = workingDirectory
            environment["OLDPWD"] = workingDirectory
            proc.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }

        let agentDir = (agentPath as NSString).deletingLastPathComponent

        if let existingPath = environment["PATH"] {
            environment["PATH"] = "\(agentDir):\(existingPath)"
        } else {
            environment["PATH"] = agentDir
        }

        proc.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        stdinPipe = stdin
        stdoutPipe = stdout
        stderrPipe = stderr

        proc.terminationHandler = { [weak self] process in
            Task {
                await self?.handleTermination(exitCode: process.terminationStatus)
            }
        }

        try proc.run()
        process = proc
        processGroupId = nil
        if proc.processIdentifier > 0 {
            let pid = proc.processIdentifier
            if setpgid(pid, pid) == 0 {
                processGroupId = pid
            } else {
                logger.warning(
                    "Failed to set process group for pid=\(pid): \(String(cString: strerror(errno)))")
            }
        }
        if proc.processIdentifier > 0 {
            let pid = proc.processIdentifier
            let pgid = processGroupId
            Task {
                await ProcessRegistry.shared.recordProcess(pid: pid, pgid: pgid, agentPath: actualPath)
            }
        }

        startOutputProcessing()
        startReading()
        startReadingStderr()
    }

    func isRunning() -> Bool {
        return process?.isRunning == true
    }

    func processIdentifier() -> Int32? {
        guard process?.isRunning == true, let pid = process?.processIdentifier, pid > 0 else {
            return nil
        }
        return pid
    }

    func processGroupIdentifier() -> Int32? {
        guard process?.isRunning == true else { return nil }
        return processGroupId
    }

    func stderrLines() -> AsyncStream<String>? {
        guard process != nil else { return nil }
        return stderrLineStream
    }

    func terminate() async {
        let proc = process
        let pgid = processGroupId
        let pid = proc?.processIdentifier

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        try? stdinPipe?.fileHandleForWriting.close()
        try? stdoutPipe?.fileHandleForReading.close()
        try? stderrPipe?.fileHandleForReading.close()

        await finishOutputProcessing()

        if let proc, proc.isRunning {
            if let pgid {
                _ = killpg(pgid, SIGTERM)
            } else {
                proc.terminate()
            }
        }

        if let proc {
            let exited = await waitForExit(proc, timeout: 2.0)
            if !exited, proc.processIdentifier > 0 {
                if let pgid {
                    _ = killpg(pgid, SIGKILL)
                } else {
                    _ = kill(proc.processIdentifier, SIGKILL)
                }
            }
        }
        await ProcessRegistry.shared.removeProcess(pid: pid, pgid: pgid)
        process = nil
        processGroupId = nil

        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil

        readBuffer.removeAll()
    }

    // MARK: - I/O Operations

    func writeMessage<T: Encodable & Sendable>(_ message: T) async throws {
        guard let stdin = stdinPipe?.fileHandleForWriting else {
            throw ClientError.processNotRunning
        }

        let data = try encoder.encode(message)

        var lineData = data
        lineData.append(0x0A)

        try stdin.write(contentsOf: lineData)
    }

    // MARK: - Callbacks

    func setDataReceivedCallback(_ callback: @escaping (Data) async -> Void) {
        self.onDataReceived = callback
    }

    func setTerminationCallback(_ callback: @escaping (Int32) async -> Void) {
        self.onTermination = callback
    }

    // MARK: - Private Methods

    private func startOutputProcessing() {
        var stderrContinuation: AsyncStream<String>.Continuation!
        stderrLineStream = AsyncStream { stderrContinuation = $0 }
        stderrLineContinuation = stderrContinuation
        stderrBuffer.removeAll(keepingCapacity: true)

        var outputContinuation: AsyncStream<OutputChunk>.Continuation!
        let outputStream = AsyncStream<OutputChunk>(bufferingPolicy: .unbounded) {
            outputContinuation = $0
        }
        self.outputContinuation = outputContinuation
        outputConsumerTask = Task { [weak self] in
            for await chunk in outputStream {
                guard let self else { return }
                await self.processOutput(chunk)
            }
        }
    }

    private func startReading() {
        guard let stdout = stdoutPipe?.fileHandleForReading,
            let outputContinuation
        else { return }

        stdout.readabilityHandler = { handle in
            let data = handle.availableData

            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }

            outputContinuation.yield(.stdout(data))
        }
    }

    private func startReadingStderr() {
        guard let stderr = stderrPipe?.fileHandleForReading,
            let outputContinuation
        else { return }

        stderr.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            outputContinuation.yield(.stderr(data))
        }
    }

    private func processOutput(_ chunk: OutputChunk) async {
        switch chunk {
        case .stdout(let data):
            await processIncomingData(data)
        case .stderr(let data):
            processStderrData(data)
        }
    }

    private func processStderrData(_ data: Data) {
        stderrBuffer.append(data)

        while let newlineIndex = stderrBuffer.firstIndex(of: 0x0A) {
            var line = Data(stderrBuffer[..<newlineIndex])
            let removeCount = stderrBuffer.distance(from: stderrBuffer.startIndex, to: newlineIndex) + 1
            stderrBuffer.removeFirst(min(removeCount, stderrBuffer.count))
            if line.last == 0x0D {
                line.removeLast()
            }
            stderrLineContinuation?.yield(String(decoding: line, as: UTF8.self))
        }
    }

    private func finishOutputProcessing() async {
        outputContinuation?.finish()
        if let outputConsumerTask {
            await outputConsumerTask.value
        }
        outputConsumerTask = nil
        outputContinuation = nil

        if !stderrBuffer.isEmpty {
            stderrLineContinuation?.yield(String(decoding: stderrBuffer, as: UTF8.self))
            stderrBuffer.removeAll(keepingCapacity: true)
        }
        stderrLineContinuation?.finish()
        stderrLineContinuation = nil
        stderrLineStream = nil
    }

    private func processIncomingData(_ data: Data) async {
        readBuffer.append(data)

        await drainBufferedMessages()
    }

    private func handleTermination(exitCode: Int32) async {
        let pid = process?.processIdentifier
        let pgid = processGroupId
        await drainAndClosePipes()
        logger.info("Agent process terminated with code: \(exitCode)")
        await ProcessRegistry.shared.removeProcess(pid: pid, pgid: pgid)
        await onTermination?(exitCode)
    }

    private func drainAndClosePipes() async {
        if let stdoutHandle = stdoutPipe?.fileHandleForReading {
            stdoutHandle.readabilityHandler = nil
            do {
                while true {
                    guard let chunk = try stdoutHandle.read(upToCount: 65536), !chunk.isEmpty else {
                        break
                    }
                    outputContinuation?.yield(.stdout(chunk))
                }
            } catch {
                // Handle already closed or invalid file handles safely
            }
            try? stdoutHandle.close()
        }

        if let stderrHandle = stderrPipe?.fileHandleForReading {
            stderrHandle.readabilityHandler = nil
            do {
                while true {
                    guard let chunk = try stderrHandle.read(upToCount: 65536), !chunk.isEmpty else {
                        break
                    }
                    outputContinuation?.yield(.stderr(chunk))
                }
            } catch {
                // Handle already closed or invalid file handles safely
            }
            try? stderrHandle.close()
        }

        await finishOutputProcessing()
        await flushRemainingBufferIfNeeded()

        try? stdinPipe?.fileHandleForWriting.close()

        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        process = nil
        processGroupId = nil
        readBuffer.removeAll()
    }

    // MARK: - JSON Message Parsing

    private func drainBufferedMessages() async {
        while let message = popNextMessage() {
            await onDataReceived?(message)
        }
    }

    private func popNextMessage() -> Data? {
        let whitespace: Set<UInt8> = [0x20, 0x09, 0x0D, 0x0A]
        parseLoop: while true {
            while let first = readBuffer.first, whitespace.contains(first) {
                readBuffer.removeFirst()
            }

            guard !readBuffer.isEmpty else {
                return nil
            }

            guard let first = readBuffer.first else { return nil }

            if first != 0x7B && first != 0x5B {
                if let jsonStart = readBuffer.firstIndex(where: { $0 == 0x7B || $0 == 0x5B }) {
                    let dropCount = readBuffer.distance(from: readBuffer.startIndex, to: jsonStart)
                    if dropCount > 0 {
                        readBuffer.removeFirst(min(dropCount, readBuffer.count))
                        logger.debug("Discarded \(dropCount) non-JSON prefix bytes before JSON start")
                    }
                    continue
                }

                if let newline = readBuffer.firstIndex(of: 0x0A) {
                    let dropped = readBuffer.prefix(upTo: newline)
                    let removeCount = readBuffer.distance(from: readBuffer.startIndex, to: newline) + 1
                    readBuffer.removeFirst(min(removeCount, readBuffer.count))
                    if !dropped.isEmpty {
                        logger.debug("Discarded non-JSON stdout line (\(dropped.count) bytes)")
                    }
                    continue
                }

                if readBuffer.count > 4096 {
                    logger.warning("Discarding \(self.readBuffer.count) bytes of non-JSON stdout")
                    self.readBuffer.removeAll(keepingCapacity: true)
                }
                return nil
            }
            let bytes = Array(readBuffer)

            var depth = 0
            var inString = false
            var escaped = false

            for endIndex in 0..<bytes.count {
                let byte = bytes[endIndex]

                if inString {
                    if escaped {
                        escaped = false
                        continue
                    }
                    if byte == 0x5C {
                        escaped = true
                        continue
                    }
                    if byte == 0x22 {
                        inString = false
                    }
                    continue
                }

                if byte == 0x22 {
                    inString = true
                    continue
                }

                if byte == 0x7B || byte == 0x5B {
                    depth += 1
                } else if byte == 0x7D || byte == 0x5D {
                    depth -= 1
                    if depth == 0 {
                        let candidate = Data(bytes[0...endIndex])
                        if isValidJSONObjectMessage(candidate) {
                            let removeCount = min(endIndex + 1, readBuffer.count)
                            readBuffer.removeFirst(removeCount)
                            return candidate
                        }

                        // Malformed JSON-like object: drop one byte and retry to re-sync.
                        logger.warning("Discarded malformed JSON-like segment (\(candidate.count) bytes)")
                        readBuffer.removeFirst(min(1, readBuffer.count))
                        continue parseLoop
                    }
                }
            }

            if let newline = readBuffer.firstIndex(of: 0x0A) {
                let line = Data(readBuffer.prefix(upTo: newline))
                if !line.isEmpty, !isValidJSONObjectMessage(line) {
                    let removeCount = readBuffer.distance(from: readBuffer.startIndex, to: newline) + 1
                    readBuffer.removeFirst(min(removeCount, readBuffer.count))
                    logger.warning("Discarded malformed JSON stdout line (\(line.count) bytes)")
                    continue
                }
            }

            if readBuffer.count > Self.largeBufferWarningThreshold {
                logger.warning("Large buffer (\(self.readBuffer.count) bytes) without complete JSON message")
            }

            return nil
        }
    }

    private func isValidJSONObjectMessage(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }

        if object is [String: Any] || object is [Any] {
            return true
        }

        return false
    }

    private func flushRemainingBufferIfNeeded() async {
        await drainBufferedMessages()

        if !readBuffer.isEmpty {
            let remaining = readBuffer
            readBuffer.removeAll(keepingCapacity: true)
            if !remaining.isEmpty {
                await onDataReceived?(remaining)
            }
        }
    }

    private func waitForExit(_ proc: Process, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return !proc.isRunning
    }
}
#endif
