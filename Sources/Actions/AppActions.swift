import AppKit

/// All AppKit access stays on the main actor; parsing/execution callers need not.
@MainActor protocol ActionWorkspace: AnyObject {
    func resolveApplication(_ name: String) -> URL?
    func openApplication(_ url: URL) async throws -> Bool
    func activateApplication(_ url: URL) async throws -> Bool
    func quitApplication(_ url: URL) async throws -> Bool
    func openWebURL(_ url: URL) throws -> Bool
}

struct AppAliases: Codable {
    let bundleIDs: [String: String]
    static let defaults = AppAliases(bundleIDs: [
        "термінал": "com.apple.Terminal", "terminal": "com.apple.Terminal",
        "пошта": "com.apple.mail", "пошту": "com.apple.mail", "mail": "com.apple.mail",
        "safari": "com.apple.Safari", "finder": "com.apple.finder",
        "нотатки": "com.apple.Notes", "notes": "com.apple.Notes",
        "textedit": "com.apple.TextEdit", "калькулятор": "com.apple.calculator",
        "calculator": "com.apple.calculator"
    ])
    /// Caller owns persistence location. Invalid config fails instead of silently changing aliases.
    static func load(from url: URL) throws -> AppAliases {
        let result = try JSONDecoder().decode(AppAliases.self, from: Data(contentsOf: url))
        guard result.bundleIDs.count <= 256, result.bundleIDs.allSatisfy({
            !$0.key.isEmpty && !$0.value.isEmpty && !$0.value.contains("/")
        }) else { throw ActionError.invalidParameters }
        return result
    }
    func save(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: [.atomic])
    }
}

@MainActor final class MacActionWorkspace: ActionWorkspace {
    private let workspace: NSWorkspace
    private let aliases: AppAliases
    init(workspace: NSWorkspace = .shared, aliases: AppAliases = .defaults) {
        self.workspace = workspace; self.aliases = aliases
    }
    func resolveApplication(_ name: String) -> URL? {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        if ["браузер", "browser"].contains(key) {
            return workspace.urlForApplication(toOpen: URL(string: "https://example.com")!)
        }
        if let id = aliases.bundleIDs[key] { return workspace.urlForApplication(withBundleIdentifier: id) }
        // Only installed applications in these explicit roots, never a supplied path.
        for root in ["/Applications", "/System/Applications", "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"] {
            let children = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil)) ?? []
            let matches = children.filter { $0.pathExtension == "app" && $0.deletingPathExtension().lastPathComponent.lowercased() == key }
            if matches.count == 1 { return matches[0] }
        }
        return nil
    }
    private func running(_ url: URL) -> [NSRunningApplication] {
        workspace.runningApplications.filter { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL && !$0.isTerminated }
    }
    func openApplication(_ url: URL) async throws -> Bool {
        try Task.checkCancellation()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let app: NSRunningApplication? = try await withCheckedThrowingContinuation { continuation in
            workspace.openApplication(at: url, configuration: config) { app, error in
                Task { @MainActor in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: app) }
                }
            }
        }
        guard let app, !app.isTerminated else { return false }
        // On a cold start the completion arrives before the app has finished
        // launching (live run 24.11.2026: Calculator and Calendar opened but were
        // reported as failed). Wait up to 3 s; a launch still in progress counts.
        for _ in 0..<60 where !app.isFinishedLaunching {
            if app.isTerminated { return false }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return !app.isTerminated
    }
    func activateApplication(_ url: URL) async throws -> Bool {
        try Task.checkCancellation()
        guard let app = running(url).first else { return false }
        guard app.activate(options: []) else { return false }
        // Activation is asynchronous; verify rather than equating acceptance with success.
        for _ in 0..<20 {
            if app.isActive { return true }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return app.isActive
    }
    func quitApplication(_ url: URL) async throws -> Bool {
        try Task.checkCancellation()
        let apps = running(url)
        guard !apps.isEmpty else { return true }
        for app in apps {
            try Task.checkCancellation()
            guard app.terminate() else { return false }
        }
        // Some apps take a few seconds to quit (Calendar took >2 s on 24.11.2026).
        for _ in 0..<100 {
            if running(url).isEmpty { return true }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return running(url).isEmpty
    }
    func openWebURL(_ url: URL) throws -> Bool {
        try Task.checkCancellation()
        return workspace.open(url)
    }
}
