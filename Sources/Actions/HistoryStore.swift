import Foundation
import Darwin

/// Only bounded action labels and status are persisted; never raw commands/parameters/errors.
struct HistoryRecord: Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let command: String
    let action: String
    let result: String
    let duration: Double
}

enum HistoryError: Error { case unsafePath, io, invalidLimit }

actor HistoryStore {
    private let directory: URL
    private let maxBytes: Int
    private let fm = FileManager.default
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Jarvis/history", isDirectory: true)
    }
    init(directory: URL = HistoryStore.defaultDirectory, maxBytes: Int = 1_048_576) throws {
        guard maxBytes >= 512, maxBytes <= 16_777_216 else { throw HistoryError.invalidLimit }
        guard directory.isFileURL, directory.path.hasPrefix("/") else { throw HistoryError.unsafePath }
        self.directory = directory; self.maxBytes = maxBytes
        try Self.prepare(self.directory)
    }
    private static func prepare(_ directory: URL) throws {
        // macOS exposes /var and /tmp as OS-owned aliases. Accept only those aliases;
        // arbitrary symlinks anywhere in the application path remain rejected.
        var rawPath = directory.path
        for (alias, real) in [("/var", "/private/var"), ("/tmp", "/private/tmp")] {
            if rawPath == alias || rawPath.hasPrefix(alias + "/") { rawPath = real + rawPath.dropFirst(alias.count) }
        }
        var current = ""
        for component in rawPath.split(separator: "/") {
            guard component != "..", component != "." else { throw HistoryError.unsafePath }
            current += "/" + component
            var st = stat()
            if lstat(current, &st) == 0 {
                guard (st.st_mode & S_IFMT) == S_IFDIR else { throw HistoryError.unsafePath }
            } else {
                guard errno == ENOENT, mkdir(current, 0o700) == 0 else { throw HistoryError.io }
            }
        }
        guard chmod(directory.path, 0o700) == 0 else { throw HistoryError.io }
    }
    private func path(_ rotated: Bool = false) -> String {
        directory.appendingPathComponent(rotated ? "history.1.jsonl" : "history.jsonl").path
    }
    private func openLog(_ name: String, flags: Int32) throws -> Int32 {
        let fd = Darwin.open(name, flags | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw HistoryError.io }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(), st.st_nlink == 1,
              fchmod(fd, 0o600) == 0 else { close(fd); throw HistoryError.unsafePath }
        return fd
    }
    func record(action: Action, outcome: CommandOutcome, duration: Double) throws {
        let kind: String
        switch action {
        case .openApp: kind = "openApp"; case .quitApp: kind = "quitApp"; case .activateApp: kind = "activateApp"
        case .openURL: kind = "openURL"; case .webSearch: kind = "webSearch"
        case .windowMinimize: kind = "windowMinimize"; case .windowMaximize: kind = "windowMaximize"
        case .windowLeftHalf: kind = "windowLeftHalf"; case .windowRightHalf: kind = "windowRightHalf"
        case .windowMinimizeAll: kind = "windowMinimizeAll"
        case .tabCloseActive: kind = "tabCloseActive"; case .tabCloseLast: kind = "tabCloseLast"
        case .tabNew: kind = "tabNew"; case .noteNew: kind = "noteNew"; case .mediaPlayPause: kind = "mediaPlayPause"
        case .tabSelect: kind = "tabSelect"; case .tabReopen: kind = "tabReopen"
        case .tabPrevious: kind = "tabPrevious"; case .tabNext: kind = "tabNext"
        case .uiSnapshot: kind = "uiSnapshot"; case .uiPress: kind = "uiPress"; case .uiSetValue: kind = "uiSetValue"
        case .runShortcut: kind = "runShortcut"
        case .clipboardRead: kind = "clipboardRead"; case .clipboardWrite: kind = "clipboardWrite"
        case .clipboardUndo: kind = "clipboardUndo"; case .clipboardPaste: kind = "clipboardPaste"
        case .volumeSet: kind = "volumeSet"; case .volumeStep: kind = "volumeStep"; case .mute: kind = "mute"
        case .dictate: kind = "dictate"
        }
        let status: String
        switch outcome {
        case .done: status = "done"; case .partial: status = "partial"; case .failed: status = "failed"
        case .needsApproval: status = "needsApproval"; case .notUnderstood: status = "notUnderstood"
        }
        let entry = HistoryRecord(id: UUID(), timestamp: Date(), command: kind, action: kind, result: status, duration: duration.isFinite ? max(0, duration) : 0)
        var data = try JSONEncoder().encode(entry); data.append(0x0a)
        try Self.prepare(directory)
        let fd = try openLog(path(), flags: O_RDWR | O_CREAT | O_APPEND)
        var shouldClose = true
        defer { if shouldClose { close(fd) } }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw HistoryError.io }
        if st.st_size > 0 {
            var last: UInt8 = 0
            guard pread(fd, &last, 1, st.st_size - 1) == 1 else { throw HistoryError.io }
            if last != 0x0a { data.insert(0x0a, at: 0) }
        }
        if st.st_size + Int64(data.count) > Int64(maxBytes) {
            close(fd); shouldClose = false
            // rename replaces a symlink itself, never its destination.
            guard rename(path(), path(true)) == 0 else { throw HistoryError.io }
            let fresh = try openLog(path(), flags: O_WRONLY | O_CREAT | O_EXCL)
            defer { close(fresh) }
            try writeAll(data, fd: fresh)
        } else { try writeAll(data, fd: fd) }
    }
    private func writeAll(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw HistoryError.io }
                offset += count
            }
        }
    }
    func read() throws -> [HistoryRecord] {
        try Self.prepare(directory)
        var records: [HistoryRecord] = []
        for name in [path(true), path()] {
            var st = stat()
            if lstat(name, &st) != 0 { if errno == ENOENT { continue }; throw HistoryError.io }
            let fd = try openLog(name, flags: O_RDONLY)
            defer { close(fd) }
            guard st.st_size <= maxBytes else { throw HistoryError.io }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = Darwin.read(fd, &buffer, buffer.count)
                if n < 0 && errno == EINTR { continue }
                guard n >= 0 else { throw HistoryError.io }
                if n == 0 { break }
                data.append(contentsOf: buffer.prefix(n))
                guard data.count <= maxBytes else { throw HistoryError.io }
            }
            for line in data.split(separator: 0x0a) {
                if let entry = try? JSONDecoder().decode(HistoryRecord.self, from: Data(line)) { records.append(entry) }
            }
        }
        return records
    }
    func clear() throws {
        try Self.prepare(directory)
        for name in [path(), path(true)] {
            if unlink(name) != 0 && errno != ENOENT { throw HistoryError.io }
        }
    }
}
