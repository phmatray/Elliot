import Foundation

enum SocketError: Error, LocalizedError {
    case pathTooLong(String)
    case syscall(String, Int32)
    case connectionClosed

    var errorDescription: String? {
        switch self {
        case .pathTooLong(let path):
            "Socket path is too long for sun_path: \(path)"
        case .syscall(let name, let code):
            "\(name) failed: \(String(cString: strerror(code))) (\(code))"
        case .connectionClosed:
            "The connection closed before a reply arrived."
        }
    }
}

/// The bits of BSD sockets Elliot needs.
///
/// Raw sockets rather than `NWListener`: its Unix-domain support is thinly
/// documented and has surprising teardown behaviour, and this is 100 lines with
/// nothing hidden.
public enum UnixSocket {

    /// The most bytes `sun_path` will hold — 104 on macOS, read from the
    /// platform rather than written down, exactly as the bind below always did.
    ///
    /// Public because the MCP helper has to answer the same question the app
    /// does before it can tell an agent why a call failed. Both processes derive
    /// the socket path from `ELLIOT_HOME` instead of exchanging it, so the
    /// helper can measure a path it has never bound — which is the whole reason
    /// #168 was cheap to fix.
    public static var maxPathBytes: Int { MemoryLayout.size(ofValue: sockaddr_un().sun_path) }

    /// Whether `bind` and `connect` will accept this path.
    ///
    /// `<`, not `<=`: `strcpy` writes a terminating NUL, so the last byte of the
    /// field is not available to the path. `makeAddress` calls this rather than
    /// repeating the comparison, because a checker that says yes to a path the
    /// binder then refuses is worse than no checker — it moves the confusing
    /// failure one layer further from its cause.
    public static func pathFits(_ path: String) -> Bool { path.utf8.count < maxPathBytes }

    /// Why the app could never have bound this path — the *fact*, with no
    /// advice attached.
    ///
    /// The words that explain it to an agent live at the one place that says
    /// them (`AppBridge`), because advice is audience-specific and this is not:
    /// it is a property of `sockaddr_un` and the filesystem, which is why it
    /// sits beside ``pathFits``.
    public enum PathObstruction: Equatable, Sendable {
        /// Longer than `sun_path` will hold. The only cause #168 covered.
        case tooLong(bytes: Int, limit: Int)
        /// The directory the socket would live in does not exist.
        case directoryMissing(String)
        /// Something is there, but it is not a directory.
        case notADirectory(String)
        /// It exists and is a directory, and this process may not create in it.
        case directoryNotWritable(String)
    }

    /// What stops `bind` from ever succeeding at `path`, or `nil` when nothing
    /// knowable does.
    ///
    /// ⛔ **The socket-file check on line two is what makes this safe to run
    /// ahead of "is the app up", and it is not an optimisation.** A live socket
    /// needs its *directory* writable only at bind time; `connect` needs no such
    /// thing. So a directory whose permissions changed after launch would make a
    /// naive probe report an app that is running and answering as unusable —
    /// the exact inversion #193's fourth criterion forbids, and a worse lie than
    /// the one being fixed. `IPCServer` removes the file before binding and on
    /// shutdown, so its presence means something bound here; that is not this
    /// function's story to tell, and it returns `nil`.
    ///
    /// A stale file from a crashed app also returns `nil`, deliberately. The
    /// caller then finds nothing answering and says the app is not running,
    /// which is **true** — this diagnoses paths that can never work, not paths
    /// that stopped working.
    ///
    /// ⚠️ Deliberately not a bind attempt. Binding succeeds only when the app is
    /// *not* holding the path, so a probe shaped that way answers the opposite
    /// of the question on exactly the calls that matter.
    ///
    /// Nothing is written and nothing is remembered: the answer is recomputed
    /// from the filesystem each time. That is why this is the fix rather than a
    /// sentinel file the app drops on a successful `startIPC` — an artefact
    /// survives the process that vouched for it, and a confident answer that has
    /// gone stale is worse than an uncertain one.
    public static func obstruction(to path: String) -> PathObstruction? {
        guard pathFits(path) else {
            return .tooLong(bytes: path.utf8.count, limit: maxPathBytes)
        }
        let manager = FileManager.default
        // Something bound here. Whatever the directory says now, this path has
        // worked, and a live connection must not be talked out of.
        if manager.fileExists(atPath: path) { return nil }

        let directory = (path as NSString).deletingLastPathComponent
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory, isDirectory: &isDirectory) else {
            return .directoryMissing(directory)
        }
        guard isDirectory.boolValue else { return .notADirectory(directory) }
        guard manager.isWritableFile(atPath: directory) else {
            return .directoryNotWritable(directory)
        }
        return nil
    }

    static func makeAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        // Through `maxPathBytes` as well, so the size the bytes are copied into
        // and the size they were measured against are one expression. They were
        // two identical `MemoryLayout.size(ofValue:)` calls for one commit,
        // which is the drift this pair exists to prevent, inside the pair.
        let maxLength = maxPathBytes
        guard pathFits(path) else { throw SocketError.pathTooLong(path) }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxLength) { destination in
                _ = strcpy(destination, path)
            }
        }
        return address
    }

    static func bindListener(path: String, backlog: Int32 = 8) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.syscall("socket", errno) }

        var address = try makeAddress(path: path)
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw SocketError.syscall("bind", code)
        }
        // The socket carries a capability; nobody else's business.
        chmod(path, 0o600)

        guard listen(fd, backlog) == 0 else {
            let code = errno
            close(fd)
            throw SocketError.syscall("listen", code)
        }
        return fd
    }

    static func connect(path: String, timeout: TimeInterval = 0.5) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.syscall("socket", errno) }

        var timeval = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000)
        )
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeval, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeval, socklen_t(MemoryLayout<timeval>.size))

        var address = try makeAddress(path: path)
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        guard connected == 0 else {
            let code = errno
            close(fd)
            throw SocketError.syscall("connect", code)
        }
        return fd
    }

    /// Reads until a newline. Returns nil at end of stream.
    ///
    /// One connection's worth of state, because a buffered read pulls the front
    /// of the *next* frame in with the end of this one and dropping that would
    /// lose a request. A free function cannot hold it.
    ///
    /// Buffered rather than a `read()` per byte: a card page is up to five
    /// hundred rows, `IPCClient` opens a connection per request, and that was a
    /// syscall per byte of every answer, twice — once on each side.
    final class LineReader {
        private let fd: Int32
        private let limit: Int
        private var pending = Data()

        init(fd: Int32, limit: Int = 8 * 1024 * 1024) {
            self.fd = fd
            self.limit = limit
        }

        func next() -> Data? {
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                if let newline = pending.firstIndex(of: 0x0A) {
                    let line = Data(pending[pending.startIndex..<newline])
                    pending = Data(pending[pending.index(after: newline)...])
                    return line
                }
                // A frame this long is a client that has stopped framing.
                if pending.count >= limit { return take() }

                let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                // Both ends of the stream, and the socket timeout, arrive here:
                // whatever was already buffered is the answer, and nothing is.
                guard n > 0 else { return pending.isEmpty ? nil : take() }
                pending.append(contentsOf: chunk[0..<n])
            }
        }

        private func take() -> Data {
            defer { pending = Data() }
            return pending
        }
    }

    static func write(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard written > 0 else { throw SocketError.syscall("write", errno) }
                offset += written
            }
        }
    }

    /// Whether something is already listening on `path`.
    ///
    /// A socket file left behind by a crash still exists but refuses
    /// connections; that is the difference between "another Elliot is running"
    /// and "clean this up and bind".
    static func isLive(path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        guard let fd = try? connect(path: path, timeout: 0.2) else { return false }
        close(fd)
        return true
    }
}
