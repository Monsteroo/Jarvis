import Foundation

@main struct DictationHistoryTests {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ label: String) { guard value else { fatalError(label) }; count += 1 }
        let field = FakeTextField()
        let access = FakeTextAccess(field)
        let dictation = DictationActions(access: access)
        let token = try dictation.capture()
        check(dictation.insert("світе", token: token, language: "uk") == .done(summary: "Текст вставлено."), "Insert verified")
        check(field.value == "Привіт, світе!", "Replace selection, preserve surrounding text")
        check(field.writes == 1, "Exactly one write")
        if case .failed = dictation.insert("again", token: token, language: "en") { count += 1 } else { fatalError("Token replay") }
        let changed = try dictation.capture()
        field.focused = false
        if case .failed = dictation.insert("x", token: changed, language: "en") { count += 1 } else { fatalError("Changed focus") }
        check(field.writes == 1, "Wrong target untouched")
        field.focused = true
        let edited = try dictation.capture()
        field.value += "edit"
        if case .failed = dictation.insert("x", token: edited, language: "uk") { count += 1 } else { fatalError("Edited content") }
        let cancelled = try dictation.capture(); dictation.invalidate()
        if case .failed = dictation.insert("x", token: cancelled, language: "en") { count += 1 } else { fatalError("Invalidated token") }
        field.safe = false
        check((try? dictation.capture()) == nil, "Secure/unsupported rejected before reading")
        field.safe = true; field.selection = NSRange(location: 0, length: 0)
        let ignored = try dictation.capture(); field.ignore = true
        if case .partial = dictation.insert("test", token: ignored, language: "en") { count += 1 } else { fatalError("Unconfirmed insertion") }
        field.ignore = false
        let beforeCancel = field.writes, toCancel = try dictation.capture()
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return dictation.insert("x", token: toCancel, language: "uk")
        }
        if case .failed = await task.value { count += 1 } else { fatalError("Cancelled insertion") }
        check(field.writes == beforeCancel, "Precancel no text write")
        var now: TimeInterval = 0
        let expiring = DictationActions(access: access, uptime: { now })
        let expired = try expiring.capture(); now = 91
        if case .failed = expiring.insert("expired", token: expired, language: "en") { count += 1 } else { fatalError("Token expiry") }
        let firstToken = try dictation.capture(), newerToken = try dictation.capture()
        if case .failed = dictation.insert("old", token: firstToken, language: "en") { count += 1 } else { fatalError("Superseded token") }
        if case .done = dictation.insert("new", token: newerToken, language: "en") { count += 1 } else { fatalError("New token still valid") }
        check((try? TextSnapshot(value: "😀", selection: NSRange(location: 1, length: 0)).replacing(with: "a")) == nil, "Reject broken UTF16 selection")
        check(try TextSnapshot(value: "😀!", selection: NSRange(location: 0, length: 2)).replacing(with: "Київ") == "Київ!", "Unicode selection")
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try HistoryStore(directory: root, maxBytes: 1024)
        try await history.record(action: .dictate("PRIVATE KEY secret"), outcome: .done(summary: "secret"), duration: 0.2)
        var records = try await history.read()
        check(records.count == 1 && records[0].action == "dictate", "History action kind")
        let log = root.appendingPathComponent("history.jsonl")
        let data = try String(contentsOf: log)
        check(!data.contains("PRIVATE") && !data.contains("secret"), "No dictated text or freeform outcomes")
        check((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700, "Private directory")
        check((try FileManager.default.attributesOfItem(atPath: log.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Private log")
        let handle = try FileHandle(forWritingTo: log); try handle.seekToEnd(); try handle.write(contentsOf: Data("broken line\n".utf8)); try handle.close()
        records = try await history.read()
        check(records.count == 1, "Corrupt line skipped")
        let cut = try FileHandle(forWritingTo: log)
        let size = try cut.seekToEnd(); try cut.truncate(atOffset: size - 1); try cut.close()
        try await history.record(action: .mute(true), outcome: .done(summary: "ok"), duration: 0)
        check(try await history.read().count == 2, "Recover after incomplete last line")
        for _ in 0..<12 { try await history.record(action: .webSearch("SECRET SEARCH"), outcome: .failed(reason: "secret"), duration: 1) }
        check(FileManager.default.fileExists(atPath: root.appendingPathComponent("history.1.jsonl").path), "Rotation")
        check(try await history.read().count > 0, "Read rotated records")
        try await history.clear()
        check(try await history.read().isEmpty, "Clear both logs")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        check((try? HistoryStore(directory: alias)) == nil, "Reject arbitrary directory symlink")
        let handler = ActionExecutor(workspace: HistoryWorkspace(), dictation: dictation, history: history)
        let handlerToken = try handler.captureDictationTarget()
        if case .done = await handler.handle("dictate Very private content", language: "en", dictationToken: handlerToken) { count += 1 }
        else { fatalError("Executor dictation integration") }
        check(try await history.read().count == 1, "Executor records action")
        check(!(try String(contentsOf: log)).contains("Very private"), "Executor history redacts payload")
        handler.invalidateDictationTarget()
        if case .failed = await handler.handle("dictate no token", language: "en") { count += 1 }
        else { fatalError("No implicit retargeting") }
        try await history.clear()
        let sentinel = root.appendingPathComponent("sentinel.txt")
        try Data("unchanged".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: log, withDestinationURL: sentinel)
        if case .partial = await handler.handle("open website example.com", language: "en") { count += 1 }
        else { fatalError("History failure must be visible after successful action") }
        check(try String(contentsOf: sentinel) == "unchanged", "Symlink destination never written")
        print("Dictation/history tests: \(count) checks passed")
    }
}

@MainActor final class FakeTextField: DictationField {
    var value = "Привіт, друже!", selection = NSRange(location: 8, length: 5)
    var focused = true, safe = true, ignore = false
    var writes = 0
    func isSafeAndFocused() -> Bool { safe && focused }
    func snapshot() throws -> TextSnapshot { TextSnapshot(value: value, selection: selection) }
    func replaceSelection(_ text: String) throws {
        writes += 1
        if !ignore { value = (value as NSString).replacingCharacters(in: selection, with: text) }
    }
}
@MainActor final class FakeTextAccess: DictationAccess {
    let field: FakeTextField
    init(_ field: FakeTextField) { self.field = field }
    func focusedField() throws -> DictationField { field }
}

@MainActor final class HistoryWorkspace: ActionWorkspace {
    func resolveApplication(_ name: String) -> URL? { nil }
    func openApplication(_ url: URL) async throws -> Bool { false }
    func activateApplication(_ url: URL) async throws -> Bool { false }
    func quitApplication(_ url: URL) async throws -> Bool { false }
    func openWebURL(_ url: URL) throws -> Bool { true }
}
