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
enum UnixSocket {

    static func makeAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxLength else { throw SocketError.pathTooLong(path) }
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
    static func readLine(fd: Int32, limit: Int = 8 * 1024 * 1024) -> Data? {
        var line = Data()
        var byte: UInt8 = 0
        while line.count < limit {
            let n = read(fd, &byte, 1)
            if n == 0 { return line.isEmpty ? nil : line }
            if n < 0 { return line.isEmpty ? nil : line }
            if byte == 0x0A { return line }
            line.append(byte)
        }
        return line
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
