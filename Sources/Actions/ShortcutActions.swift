import AppKit
import ApplicationServices

/// Fixed keyboard shortcuts for common requests, so they need no window reading:
/// a new browser tab (⌘T), a new note (⌘N in Notes) and the play/pause media key
/// (pauses or resumes a YouTube video in the browser, or music). The key goes
/// only to the application just brought forward, checked right before posting.
enum ShortcutKey: Equatable, Sendable { case newTab, newNote, reopenTab, selectTab(Int), previousTab, nextTab }

enum ShortcutError: Error, Equatable {
    case untrusted, noBrowser, appNotFound, notFrontmost
}

@MainActor protocol ShortcutAccess {
    var trusted: Bool { get }
    /// Brings the application forward, launching it if needed; returns its name and pid.
    func bringForward(appQuery: String?, browser: Bool) async throws -> (name: String, pid: pid_t)
    /// Posts the shortcut, but only if `pid` is still the frontmost application.
    func press(_ key: ShortcutKey, expectedPID: pid_t) throws
    func playPause() throws
}

@MainActor final class ShortcutActions {
    let access: ShortcutAccess
    init(access: ShortcutAccess) { self.access = access }

    func perform(_ action: Action, language: String) async -> CommandOutcome {
        guard access.trusted else {
            return .failed(reason: actionText(language,
                "Надайте Jarvis дозвіл у Системні параметри → Приватність і безпека → Доступність.",
                "Allow Jarvis in System Settings → Privacy & Security → Accessibility."))
        }
        do {
            switch action {
            case .tabNew(let app):
                let target = try await access.bringForward(appQuery: app, browser: true)
                try Task.checkCancellation()
                try access.press(.newTab, expectedPID: target.pid)
                return .done(summary: actionText(language, "Нову вкладку у «\(target.name)» відкрито.", "Opened a new tab in ‘\(target.name)’."))
            case .noteNew:
                let target = try await access.bringForward(appQuery: "com.apple.Notes", browser: false)
                try Task.checkCancellation()
                try access.press(.newNote, expectedPID: target.pid)
                return .done(summary: actionText(language, "Нову нотатку створено.", "Created a new note."))
            case .tabSelect(let index):
                let target = try await access.bringForward(appQuery: nil, browser: true)
                try Task.checkCancellation()
                try access.press(.selectTab(index), expectedPID: target.pid)
                return .done(summary: index == 9
                    ? actionText(language, "Перейшов на останню вкладку у «\(target.name)».", "Switched to the last tab in ‘\(target.name)’.")
                    : actionText(language, "Перейшов на вкладку \(index) у «\(target.name)».", "Switched to tab \(index) in ‘\(target.name)’."))
            case .tabReopen:
                let target = try await access.bringForward(appQuery: nil, browser: true)
                try Task.checkCancellation()
                try access.press(.reopenTab, expectedPID: target.pid)
                return .done(summary: actionText(language, "Закриту вкладку у «\(target.name)» повернуто.", "Reopened the closed tab in ‘\(target.name)’."))
            case .tabPrevious, .tabNext:
                let next = action == .tabNext
                let target = try await access.bringForward(appQuery: nil, browser: true)
                try Task.checkCancellation()
                try access.press(next ? .nextTab : .previousTab, expectedPID: target.pid)
                return .done(summary: next
                    ? actionText(language, "Перейшов на наступну вкладку.", "Switched to the next tab.")
                    : actionText(language, "Перейшов на попередню вкладку.", "Switched to the previous tab."))
            case .mediaPlayPause:
                try access.playPause()
                return .done(summary: actionText(language, "Паузу або відтворення перемкнено.", "Toggled play/pause."))
            default:
                return .failed(reason: actionText(language, "Ця дія не підтримується.", "This action is not supported."))
            }
        } catch is CancellationError {
            return .failed(reason: actionText(language, "Запит скасовано.", "Request cancelled."))
        } catch let error as ShortcutError {
            switch error {
            case .untrusted:
                return .failed(reason: actionText(language, "Немає дозволу Доступність для Jarvis.", "Jarvis has no Accessibility permission."))
            case .noBrowser:
                return .failed(reason: actionText(language, "Браузер не відкрито.", "No browser is open."))
            case .appNotFound:
                return .failed(reason: actionText(language, "Програму не знайдено.", "Application not found."))
            case .notFrontmost:
                return .failed(reason: actionText(language, "Не вдалося вивести програму на передній план; нічого не натиснуто.",
                                                  "Could not bring the application to the front; nothing was pressed."))
            }
        } catch {
            return .failed(reason: actionText(language, "Не вдалося виконати дію.", "The action failed."))
        }
    }
}

@MainActor struct MacShortcutAccess: ShortcutAccess {
    static let browserBundles: [String] = [
        "com.google.chrome", "com.apple.safari", "company.thebrowser.browser",
        "com.brave.browser", "com.microsoft.edgemac", "org.mozilla.firefox",
    ]
    private static let names: [String: String] = [
        "chrome": "com.google.chrome", "google chrome": "com.google.chrome", "хром": "com.google.chrome",
        "safari": "com.apple.safari", "сафарі": "com.apple.safari", "arc": "company.thebrowser.browser",
        "brave": "com.brave.browser", "edge": "com.microsoft.edgemac", "firefox": "org.mozilla.firefox",
    ]

    var trusted: Bool { AXIsProcessTrusted() }

    func bringForward(appQuery: String?, browser: Bool) async throws -> (name: String, pid: pid_t) {
        let own = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != own && !$0.isTerminated && $0.activationPolicy == .regular
        }
        var bundle: String?
        if let raw = appQuery?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty {
            bundle = Self.names[raw] ?? (raw.contains(".") ? raw : nil)
            if bundle == nil, let match = running.first(where: { ($0.localizedName ?? "").lowercased() == raw }) {
                bundle = match.bundleIdentifier?.lowercased()
            }
            guard bundle != nil else { throw browser ? ShortcutError.noBrowser : ShortcutError.appNotFound }
        } else if browser {
            // The front browser, else the topmost browser window, else any running browser.
            if let pid = MacWindowAccess.frontApplicationPID(), let front = NSRunningApplication(processIdentifier: pid),
               let bid = front.bundleIdentifier?.lowercased(), Self.browserBundles.contains(bid) {
                bundle = bid
            } else if let bid = running.compactMap({ $0.bundleIdentifier?.lowercased() }).first(where: Self.browserBundles.contains) {
                bundle = bid
            }
            guard bundle != nil else { throw ShortcutError.noBrowser }
        }
        guard let bundle else { throw ShortcutError.appNotFound }
        if browser, !Self.browserBundles.contains(bundle) { throw ShortcutError.noBrowser }

        var app = running.first { $0.bundleIdentifier?.lowercased() == bundle }
        if app == nil {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { throw ShortcutError.appNotFound }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            app = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSRunningApplication?, Error>) in
                NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
                    Task { @MainActor in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: app) }
                    }
                }
            }
        }
        guard let app else { throw ShortcutError.appNotFound }
        app.activate(options: [])
        // Up to 3 s for a cold start and for activation to land.
        for _ in 0..<60 {
            if app.isFinishedLaunching, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await Task.sleep(nanoseconds: 150_000_000) // let the window become key
        return (app.localizedName ?? bundle, app.processIdentifier)
    }

    func press(_ key: ShortcutKey, expectedPID: pid_t) throws {
        guard trusted else { throw ShortcutError.untrusted }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedPID else { throw ShortcutError.notFrontmost }
        let digits: [CGKeyCode] = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19] // kVK_ANSI_1…9
        let code: CGKeyCode
        var flags: CGEventFlags = .maskCommand
        switch key {
        case .newTab: code = 0x11 // kVK_ANSI_T
        case .newNote: code = 0x2D // kVK_ANSI_N
        case .reopenTab: code = 0x11; flags.insert(.maskShift)
        case .nextTab: code = 0x30; flags = .maskControl // kVK_Tab
        case .previousTab: code = 0x30; flags = [.maskControl, .maskShift]
        case .selectTab(let index):
            guard (1...9).contains(index) else { throw ShortcutError.appNotFound }
            code = digits[index - 1]
        }
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { throw ShortcutError.notFrontmost }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    func playPause() throws {
        guard trusted else { throw ShortcutError.untrusted }
        let play = 16 // NX_KEYTYPE_PLAY
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                           modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           subtype: 8, data1: (play << 16) | (state << 8), data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
