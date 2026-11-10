import Foundation
import Darwin

struct AgentIPCEndpoint: Sendable {
    let socketPath: String
    let capability: String // IPC capability, not a native action-approval token. Never log it.
}

enum AgentSocket {
    static func create() throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentError.unavailable }
        do { try configure(fd); return fd } catch { Darwin.close(fd); throw error }
    }
    static func configure(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        // Darwin accept() inherits O_NONBLOCK from the listening socket.
        guard flags >= 0, fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0 else { throw AgentError.unavailable }
        var yes: Int32 = 1, timeout = timeval(tv_sec: 120, tv_usec: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else { throw AgentError.unavailable }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw AgentError.unavailable }
    }
    static func address<T>(_ path: String, _ operation: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw AgentError.invalidConfiguration }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes) }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { operation($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
    static func verifyPeer(_ fd: Int32) throws {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw AgentError.invalidConfiguration }
    }
    static func send(_ value: JSONValue, fd: Int32) throws {
        var data = try JSONEncoder().encode(value)
        guard data.count <= 262_144 else { throw AgentError.invalidMessage }
        data.append(0x0a)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw AgentError.closed }; offset += n
            }
        }
    }
}

/// Single reader per fd; works for helper stdin as well as the private socket.
final class AgentFrameReader {
    private let fd: Int32
    private var buffer = Data()
    init(_ fd: Int32) { self.fd = fd }
    func next() throws -> JSONValue? {
        while true {
            if let end = buffer.firstIndex(of: 0x0a) {
                let line = buffer.prefix(upTo: end); buffer.removeSubrange(...end)
                if line.isEmpty { continue }
                guard line.count <= 262_144 else { throw AgentError.invalidMessage }
                return try JSONDecoder().decode(JSONValue.self, from: line)
            }
            guard buffer.count <= 262_144 else { throw AgentError.invalidMessage }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let n = Darwin.read(fd, &bytes, bytes.count)
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw AgentError.closed }
            if n == 0 { guard buffer.isEmpty else { throw AgentError.invalidMessage }; return nil }
            buffer.append(contentsOf: bytes.prefix(n))
        }
    }
}

final class AgentIPCConnection {
    private let fd: Int32
    private let reader: AgentFrameReader
    private let endpoint: AgentIPCEndpoint
    init(endpoint: AgentIPCEndpoint) throws {
        guard endpoint.capability.utf8.count == 64 else { throw AgentError.invalidConfiguration }
        var st = stat()
        guard lstat(endpoint.socketPath, &st) == 0, st.st_uid == getuid(), (st.st_mode & S_IFMT) == S_IFSOCK,
              (st.st_mode & 0o777) == 0o600 else { throw AgentError.invalidConfiguration }
        let socket = try AgentSocket.create()
        do {
            guard try AgentSocket.address(endpoint.socketPath, { Darwin.connect(socket, $0, $1) }) == 0 else { throw AgentError.unavailable }
            try AgentSocket.verifyPeer(socket)
        } catch { Darwin.close(socket); throw error }
        fd = socket; reader = AgentFrameReader(socket); self.endpoint = endpoint
    }
    deinit { Darwin.close(fd) }
    func exchange(_ message: JSONValue) throws -> JSONValue? {
        try AgentSocket.send(.object(["capability": .string(endpoint.capability), "message": message]), fd: fd)
        guard let reply = try reader.next() else { throw AgentError.closed }
        return reply["message"] == .null ? nil : reply["message"]
    }
}
