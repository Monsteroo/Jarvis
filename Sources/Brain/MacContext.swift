import AppKit

/// What the brain may know about the Mac: application names only (installed,
/// running, frontmost). Never window titles or contents: those could carry
/// instructions from web pages or documents.
struct MacContext {
    var installed: [String]
    var running: [String]
    var frontmost: String?

    private static var cachedInstalled: [String]?

    /// Installed applications from the same roots the executor resolves.
    static func installedApps(refresh: Bool = false) -> [String] {
        if let cachedInstalled, !refresh { return cachedInstalled }
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications",
                     "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        var names = Set<String>()
        for root in roots {
            for item in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] where item.hasSuffix(".app") {
                names.insert(String(item.dropLast(4)))
            }
        }
        let list = Array(names).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.prefix(300)
        cachedInstalled = Array(list)
        return cachedInstalled!
    }

    static func current() -> MacContext {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        return MacContext(installed: installedApps(),
                          // Bundle file names ("Viber", "Calendar"), the names the executor
                          // resolves; localizedName gives "Rakuten Viber" or "Календар".
                          running: apps.compactMap { $0.bundleURL?.deletingPathExtension().lastPathComponent ?? $0.localizedName }
                              .filter { $0 != "Jarvis Voice Lab" },
                          frontmost: NSWorkspace.shared.frontmostApplication?.localizedName)
    }

    /// Could the executor find this application by the spoken name? Pass
    /// file names only: running apps report localized names ("Календар" on a
    /// Ukrainian Mac) that the executor cannot open. Used to
    /// send "відкрий календар" or "YouTube в Google Chrome" to the brain
    /// instead of failing with "not found".
    static func resolvable(_ name: String, installed: [String], running: [String], aliases: [String]) -> Bool {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return false }
        if ["браузер", "browser"].contains(key) || aliases.contains(key) { return true }
        return (installed + running).contains { $0.lowercased() == key }
    }

    /// Dynamic line that goes with each request.
    func line(language: String) -> String {
        let open = running.prefix(20).joined(separator: ", ")
        if language == "en" {
            return "Open applications: \(open.isEmpty ? "none" : open). Front: \(frontmost ?? "unknown")."
        }
        return "Відкриті програми: \(open.isEmpty ? "немає" : open). На передньому плані: \(frontmost ?? "невідомо")."
    }
}
