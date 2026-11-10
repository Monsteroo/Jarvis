import Foundation
import Darwin

/// Small local files only. Callers serialize transactions with the separate lock file.
enum PrivateAgentFiles {
    static func directory(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw AgentError.invalidConfiguration }
        var path = url.path
        for (alias, real) in [("/var", "/private/var"), ("/tmp", "/private/tmp")] {
            if path == alias || path.hasPrefix(alias + "/") { path = real + path.dropFirst(alias.count) }
        }
        var current = ""
        for part in path.split(separator: "/") {
            guard part != "..", part != "." else { throw AgentError.invalidConfiguration }
            current += "/" + part
            var st = stat()
            if lstat(current, &st) == 0 {
                guard (st.st_mode & S_IFMT) == S_IFDIR else { throw AgentError.invalidConfiguration }
            } else if errno != ENOENT || mkdir(current, 0o700) != 0 { throw AgentError.unavailable }
        }
        var st = stat()
        guard lstat(url.path, &st) == 0, st.st_uid == getuid(), chmod(url.path, 0o700) == 0 else { throw AgentError.unavailable }
    }
    static func lock<T>(_ url: URL, _ operation: () throws -> T) throws -> T {
        try directory(url.deletingLastPathComponent())
        let fd = try openRegular(url.path + ".lock", flags: O_RDWR | O_CREAT)
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw AgentError.unavailable }
        defer { flock(fd, LOCK_UN) }
        return try operation()
    }
    private static func openRegular(_ path: String, flags: Int32) throws -> Int32 {
        let fd = Darwin.open(path, flags | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AgentError.unavailable }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(), st.st_nlink == 1,
              fchmod(fd, 0o600) == 0 else { close(fd); throw AgentError.invalidConfiguration }
        return fd
    }
    static func read(_ url: URL) throws -> Data? {
        var st = stat()
        if lstat(url.path, &st) != 0 {
            guard errno == ENOENT else { throw AgentError.unavailable }; return nil
        }
        let fd = try openRegular(url.path, flags: O_RDONLY)
        defer { close(fd) }
        guard st.st_size <= 1_048_576 else { throw AgentError.invalidConfiguration }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(fd, &bytes, bytes.count)
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw AgentError.unavailable }
            if n == 0 { return data }
            data.append(contentsOf: bytes.prefix(n))
            guard data.count <= 1_048_576 else { throw AgentError.invalidConfiguration }
        }
    }
    static func write(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".jarvis-" + UUID().uuidString)
        let fd = try openRegular(temp.path, flags: O_WRONLY | O_CREAT | O_EXCL)
        defer { close(fd); unlink(temp.path) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw AgentError.unavailable }; offset += n
            }
        }
        guard fsync(fd) == 0, rename(temp.path, url.path) == 0 else { throw AgentError.unavailable }
        let parent = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw AgentError.unavailable }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw AgentError.unavailable }
    }
}
