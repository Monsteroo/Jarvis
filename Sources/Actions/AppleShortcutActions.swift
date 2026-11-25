import Foundation
import Darwin

/// One owner-approved Apple Shortcut entry stored locally on this Mac.
struct AllowlistedShortcut: Codable, Equatable, Sendable, Identifiable {
    var id: String { name }
    let name: String
    var aliasesUK: [String]
    var aliasesEN: [String]
    var requiresConfirmation: Bool

    init(name: String, aliasesUK: [String] = [], aliasesEN: [String] = [], requiresConfirmation: Bool = false) {
        self.name = name
        self.aliasesUK = aliasesUK
        self.aliasesEN = aliasesEN
        self.requiresConfirmation = requiresConfirmation
    }
}

enum AppleShortcutError: Error, Equatable {
    case unsafePath
    case io
    case invalidName
    case invalidData
    case timedOut
    case cancelled
    case failed(Int32)
}

/// Private local allowlist at ~/Library/Application Support/Jarvis/shortcuts-allowlist.json.
/// Empty by default; owner-readable/writable only (0600 file, 0700 directory, no symlinks).
final class AppleShortcutAllowlistStore: @unchecked Sendable {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Jarvis/shortcuts-allowlist.json")
    }

    let fileURL: URL
    private let lock = NSLock()
    private static let maxBytes = 524_288

    init(fileURL: URL = AppleShortcutAllowlistStore.defaultURL) {
        self.fileURL = fileURL
    }

    static func isValidShortcutName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == name, (1...128).contains(name.count) else { return false }
        guard !name.hasPrefix("-") else { return false }
        guard !name.contains("/"), !name.contains("..") else { return false }
        let forbidden: Set<Character> = [";", "|", "&", "`", "$"]
        guard !name.contains(where: { forbidden.contains($0) }) else { return false }
        guard !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        return true
    }

    static func sanitizeAliases(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in raw {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 128,
                  !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted { result.append(trimmed) }
        }
        return result
    }

    func load() -> [AllowlistedShortcut] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? readData() else { return [] }
        guard let decoded = try? JSONDecoder().decode([AllowlistedShortcut].self, from: data) else { return [] }
        var seen = Set<String>()
        var clean: [AllowlistedShortcut] = []
        for entry in decoded {
            guard Self.isValidShortcutName(entry.name) else { continue }
            let key = entry.name.lowercased()
            guard seen.insert(key).inserted else { continue }
            clean.append(AllowlistedShortcut(
                name: entry.name,
                aliasesUK: Self.sanitizeAliases(entry.aliasesUK),
                aliasesEN: Self.sanitizeAliases(entry.aliasesEN),
                requiresConfirmation: entry.requiresConfirmation
            ))
        }
        return clean
    }

    func save(_ entries: [AllowlistedShortcut]) throws {
        lock.lock()
        defer { lock.unlock() }
        var seen = Set<String>()
        var sanitized: [AllowlistedShortcut] = []
        for entry in entries {
            guard Self.isValidShortcutName(entry.name) else { throw AppleShortcutError.invalidName }
            let key = entry.name.lowercased()
            guard seen.insert(key).inserted else { continue }
            sanitized.append(AllowlistedShortcut(
                name: entry.name,
                aliasesUK: Self.sanitizeAliases(entry.aliasesUK),
                aliasesEN: Self.sanitizeAliases(entry.aliasesEN),
                requiresConfirmation: entry.requiresConfirmation
            ))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sanitized)
        guard data.count <= Self.maxBytes else { throw AppleShortcutError.invalidData }
        try writeAtomic(data)
    }

    private func prepareDirectory(_ directory: URL) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/") else { throw AppleShortcutError.unsafePath }
        var path = directory.path
        for (alias, real) in [("/var", "/private/var"), ("/tmp", "/private/tmp")] {
            if path == alias || path.hasPrefix(alias + "/") {
                path = real + path.dropFirst(alias.count)
            }
        }
        var current = ""
        for part in path.split(separator: "/") {
            guard part != "..", part != "." else { throw AppleShortcutError.unsafePath }
            current += "/" + part
            var st = stat()
            if lstat(current, &st) == 0 {
                guard (st.st_mode & S_IFMT) == S_IFDIR else { throw AppleShortcutError.unsafePath }
            } else {
                guard errno == ENOENT, mkdir(current, 0o700) == 0 else { throw AppleShortcutError.io }
            }
        }
        var st = stat()
        guard lstat(directory.path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_uid == getuid(),
              chmod(directory.path, 0o700) == 0 else {
            throw AppleShortcutError.unsafePath
        }
    }

    private func openRegular(_ path: String, flags: Int32) throws -> Int32 {
        let fd = Darwin.open(path, flags | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AppleShortcutError.io }
        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == getuid(),
              st.st_nlink == 1,
              fchmod(fd, 0o600) == 0 else {
            close(fd)
            throw AppleShortcutError.unsafePath
        }
        return fd
    }

    private func readData() throws -> Data? {
        guard fileURL.isFileURL, fileURL.path.hasPrefix("/") else { throw AppleShortcutError.unsafePath }
        let directory = fileURL.deletingLastPathComponent()
        var dirStat = stat()
        if lstat(directory.path, &dirStat) != 0 {
            if errno == ENOENT { return nil }
            throw AppleShortcutError.io
        }
        try prepareDirectory(directory)
        var st = stat()
        if lstat(fileURL.path, &st) != 0 {
            if errno == ENOENT { return nil }
            throw AppleShortcutError.io
        }
        let fd = try openRegular(fileURL.path, flags: O_RDONLY)
        defer { close(fd) }
        guard st.st_size <= Self.maxBytes else { throw AppleShortcutError.invalidData }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw AppleShortcutError.io }
            if n == 0 { return data }
            data.append(contentsOf: buffer.prefix(n))
            guard data.count <= Self.maxBytes else { throw AppleShortcutError.invalidData }
        }
    }

    private func writeAtomic(_ data: Data) throws {
        guard fileURL.isFileURL, fileURL.path.hasPrefix("/") else { throw AppleShortcutError.unsafePath }
        let directory = fileURL.deletingLastPathComponent()
        try prepareDirectory(directory)
        let temp = directory.appendingPathComponent(".jarvis-shortcuts-" + UUID().uuidString)
        let fd = try openRegular(temp.path, flags: O_WRONLY | O_CREAT | O_EXCL)
        defer { close(fd); unlink(temp.path) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw AppleShortcutError.io }
                offset += n
            }
        }
        guard fsync(fd) == 0, rename(temp.path, fileURL.path) == 0 else { throw AppleShortcutError.io }
        let parent = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw AppleShortcutError.io }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw AppleShortcutError.io }
    }
}

@MainActor protocol AppleShortcutRunning {
    func runShortcut(named exactName: String, timeoutSeconds: TimeInterval) async throws
    func listShortcuts() async throws -> [String]
}

private final class ShortcutProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var finished = false
    private var cancelled = false
    private var timedOut = false

    init(_ process: Process) {
        self.process = process
    }

    func markFinished() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    func cancel(timedOut: Bool = false) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        if timedOut { self.timedOut = true } else { self.cancelled = true }
        let running = process.isRunning
        lock.unlock()
        if running { process.terminate() }
    }

    var state: (cancelled: Bool, timedOut: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (cancelled, timedOut)
    }
}

/// Runs Apple Shortcuts directly via /usr/bin/shortcuts without any shell.
@MainActor final class MacAppleShortcutRunner: AppleShortcutRunning {
    static let executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")

    func runShortcut(named exactName: String, timeoutSeconds: TimeInterval) async throws {
        guard AppleShortcutAllowlistStore.isValidShortcutName(exactName) else {
            throw AppleShortcutError.invalidName
        }
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = Self.executableURL
        process.arguments = ["run", exactName]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let handle = ShortcutProcessHandle(process)
        let nanos = UInt64(max(0.1, timeoutSeconds) * 1_000_000_000)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
                timer.schedule(deadline: .now() + .nanoseconds(Int(min(nanos, UInt64(Int.max)))))
                timer.setEventHandler {
                    handle.cancel(timedOut: true)
                }
                process.terminationHandler = { proc in
                    timer.cancel()
                    handle.markFinished()
                    let s = handle.state
                    if s.timedOut {
                        continuation.resume(throwing: AppleShortcutError.timedOut)
                    } else if s.cancelled {
                        continuation.resume(throwing: AppleShortcutError.cancelled)
                    } else if proc.terminationStatus == 0 {
                        continuation.resume(returning: ())
                    } else {
                        continuation.resume(throwing: AppleShortcutError.failed(proc.terminationStatus))
                    }
                }
                do {
                    try process.run()
                    timer.resume()
                } catch {
                    timer.cancel()
                    handle.markFinished()
                    continuation.resume(throwing: AppleShortcutError.io)
                }
            }
        } onCancel: {
            handle.cancel(timedOut: false)
        }
    }

    func listShortcuts() async throws -> [String] {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = Self.executableURL
        process.arguments = ["list"]
        let stdout = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let handle = ShortcutProcessHandle(process)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
                    timer.schedule(deadline: .now() + .seconds(10))
                    timer.setEventHandler { handle.cancel(timedOut: true) }
                    do {
                        try process.run()
                        timer.resume()
                        let data = stdout.fileHandleForReading.readDataToEndOfFile()
                        process.waitUntilExit()
                        timer.cancel()
                        handle.markFinished()
                        let s = handle.state
                        if s.timedOut {
                            continuation.resume(throwing: AppleShortcutError.timedOut)
                        } else if s.cancelled {
                            continuation.resume(throwing: AppleShortcutError.cancelled)
                        } else if process.terminationStatus != 0 {
                            continuation.resume(throwing: AppleShortcutError.failed(process.terminationStatus))
                        } else {
                            let text = String(data: data, encoding: .utf8) ?? ""
                            var seen = Set<String>()
                            var names: [String] = []
                            for rawLine in text.components(separatedBy: .newlines) {
                                let name = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard AppleShortcutAllowlistStore.isValidShortcutName(name) else { continue }
                                if seen.insert(name.lowercased()).inserted { names.append(name) }
                            }
                            names.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                            continuation.resume(returning: names)
                        }
                    } catch {
                        timer.cancel()
                        handle.markFinished()
                        continuation.resume(throwing: AppleShortcutError.io)
                    }
                }
            }
        } onCancel: {
            handle.cancel(timedOut: false)
        }
    }
}

final class AppleShortcutActions: @unchecked Sendable {
    let store: AppleShortcutAllowlistStore
    private let runner: AppleShortcutRunning
    let timeoutSeconds: TimeInterval

    init(store: AppleShortcutAllowlistStore = AppleShortcutAllowlistStore(),
         runner: AppleShortcutRunning,
         timeoutSeconds: TimeInterval = 15.0) {
        self.store = store
        self.runner = runner
        self.timeoutSeconds = timeoutSeconds
    }

    @MainActor static func live(store: AppleShortcutAllowlistStore = AppleShortcutAllowlistStore()) -> AppleShortcutActions {
        AppleShortcutActions(store: store, runner: MacAppleShortcutRunner())
    }

    func allowlist() -> [AllowlistedShortcut] {
        store.load()
    }

    func allowlistedNames() -> [String] {
        store.load().map(\.name)
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?«»\"'")))
            .lowercased()
    }

    /// Resolves an exact allowlisted shortcut name or a uk/en alias.
    func resolve(_ query: String, language: String) -> AllowlistedShortcut? {
        guard language == "uk" || language == "en" else { return nil }
        let key = Self.normalized(query)
        guard !key.isEmpty else { return nil }
        let entries = store.load()
        if let exact = entries.first(where: { $0.name.lowercased() == key }) {
            return exact
        }
        let primaryMatch = entries.first { entry in
            let list = language == "en" ? entry.aliasesEN : entry.aliasesUK
            return list.contains { Self.normalized($0) == key }
        }
        if let primaryMatch { return primaryMatch }
        return entries.first { entry in
            let fallback = language == "en" ? entry.aliasesUK : entry.aliasesEN
            return fallback.contains { Self.normalized($0) == key }
        }
    }

    /// Matches a bare spoken phrase directly against allowlisted uk/en aliases.
    func matchDirectPhrase(_ text: String, language: String) -> AllowlistedShortcut? {
        guard language == "uk" || language == "en" else { return nil }
        let key = Self.normalized(text)
        guard !key.isEmpty else { return nil }
        let entries = store.load()
        guard !entries.isEmpty else { return nil }
        let primary = entries.first { entry in
            let list = language == "en" ? entry.aliasesEN : entry.aliasesUK
            return list.contains { Self.normalized($0) == key }
        }
        if let primary { return primary }
        return entries.first { entry in
            let fallback = language == "en" ? entry.aliasesUK : entry.aliasesEN
            return fallback.contains { Self.normalized($0) == key }
        }
    }

    @MainActor func effectivePolicy(for action: Action) -> ApprovalPolicy? {
        guard case .runShortcut(let rawName) = action else { return nil }
        guard let entry = resolve(rawName, language: "uk") ?? resolve(rawName, language: "en") else {
            return .confirmation
        }
        return entry.requiresConfirmation ? .confirmation : .immediate
    }

    @MainActor func listAvailableShortcuts() async throws -> [String] {
        try await runner.listShortcuts()
    }

    @MainActor func perform(_ action: Action, language: String) async -> CommandOutcome {
        guard language == "uk" || language == "en" else {
            return .failed(reason: "Оберіть українську або англійську мову.")
        }
        guard case .runShortcut(let rawName) = action else {
            return .failed(reason: actionText(language, "Некоректні параметри команди.", "Invalid command parameters."))
        }
        guard let entry = resolve(rawName, language: language) else {
            return .failed(reason: actionText(
                language,
                "Команду «\(rawName)» не додано до білого списку Apple Shortcuts.",
                "Shortcut ‘\(rawName)’ is not in the Apple Shortcuts allowlist."
            ))
        }
        guard AppleShortcutAllowlistStore.isValidShortcutName(entry.name) else {
            return .failed(reason: actionText(language, "Некоректна назва команди Shortcuts.", "Invalid Apple Shortcut name."))
        }
        do {
            try Task.checkCancellation()
            try await runner.runShortcut(named: entry.name, timeoutSeconds: timeoutSeconds)
            return .done(summary: actionText(
                language,
                "Команду «\(entry.name)» виконано.",
                "Ran shortcut ‘\(entry.name)’."
            ))
        } catch is CancellationError {
            return .failed(reason: actionText(language, "Запуск команди скасовано.", "Shortcut run was cancelled."))
        } catch AppleShortcutError.cancelled {
            return .failed(reason: actionText(language, "Запуск команди скасовано.", "Shortcut run was cancelled."))
        } catch AppleShortcutError.timedOut {
            return .failed(reason: actionText(
                language,
                "Команда «\(entry.name)» перевищила ліміт часу.",
                "Shortcut ‘\(entry.name)’ timed out."
            ))
        } catch {
            return .failed(reason: actionText(
                language,
                "Не вдалося виконати команду «\(entry.name)».",
                "Failed to run shortcut ‘\(entry.name)’."
            ))
        }
    }
}
