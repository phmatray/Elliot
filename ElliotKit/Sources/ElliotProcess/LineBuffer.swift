import Foundation

/// Splits a byte stream into newline-delimited lines.
///
/// A chunk read from a pipe has no relationship to line boundaries: one event
/// can arrive split across three reads, and a single tool result can be
/// hundreds of kilobytes. Anything that assumes "one read, whole lines" corrupts
/// the log the first time a large event goes through.
public struct LineBuffer: Sendable {
    private var pending = Data()
    private var droppedOversized = 0

    /// Lines longer than this are truncated rather than allowed to exhaust
    /// memory on a runaway process.
    public let limit: Int

    public init(limit: Int = 32 * 1024 * 1024) {
        self.limit = limit
    }

    /// Feeds a chunk and returns whatever complete lines it finished.
    public mutating func append(_ chunk: Data) -> [Data] {
        pending.append(chunk)
        var lines: [Data] = []

        while let newline = pending.firstIndex(of: 0x0A) {
            var line = pending[pending.startIndex..<newline]
            // Tolerate CRLF.
            if line.last == 0x0D { line = line.dropLast() }
            lines.append(Data(line))
            pending = Data(pending[pending.index(after: newline)...])
        }

        if pending.count > limit {
            droppedOversized += 1
            pending = Data(pending.prefix(limit))
        }
        return lines
    }

    /// The trailing bytes at EOF, when the process ended without a final
    /// newline. Callers must drain this or lose the last event.
    public mutating func flush() -> Data? {
        defer { pending = Data() }
        return pending.isEmpty ? nil : pending
    }

    public var truncatedLineCount: Int { droppedOversized }
}
