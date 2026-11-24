import AppKit
import ApplicationServices

struct WindowGeometry {
    static func destination(_ action: Action, visibleFrame: CGRect) -> CGRect {
        var frame = visibleFrame
        if action == .windowLeftHalf || action == .windowRightHalf {
            frame.size.width /= 2
            if action == .windowRightHalf { frame.origin.x += frame.width }
        }
        return frame
    }
    /// AX uses a top-left origin relative to the primary display, even across displays.
    static func axFrame(fromAppKit frame: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
    }
    static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX-b.minX) <= 3 && abs(a.minY-b.minY) <= 3 && abs(a.width-b.width) <= 3 && abs(a.height-b.height) <= 3
    }
}

enum WindowAttribute { case position, size, minimized }
enum DeviceActionError: Error { case unavailable, unsupported, writeFailed }

@MainActor protocol WindowTarget: AnyObject {
    var visibleFrame: CGRect { get }
    func canSet(_ attribute: WindowAttribute) -> Bool
    func readFrame() throws -> CGRect
    func readMinimized() throws -> Bool
    func setPosition(_ point: CGPoint) throws
    func setSize(_ size: CGSize) throws
    func setMinimized(_ value: Bool) throws
}
@MainActor protocol WindowAccess {
    var trusted: Bool { get }
    func target() throws -> WindowTarget
    /// Standard, not yet minimized windows of every other application.
    func allTargets() -> [WindowTarget]
}

@MainActor struct WindowActions {
    let access: WindowAccess
    func perform(_ action: Action, language: String) async -> CommandOutcome {
        let fail = actionText(language, "Не вдалося змінити вікно. Воно може не підтримувати цю дію.", "Unable to change the window. It may not support this action.")
        guard !Task.isCancelled else { return .failed(reason: actionText(language, "Запит скасовано.", "Request cancelled.")) }
        guard access.trusted else {
            return .failed(reason: actionText(language, "Надайте Jarvis дозвіл у Системні параметри → Приватність і безпека → Доступність.", "Allow Jarvis in System Settings → Privacy & Security → Accessibility."))
        }
        if action == .windowMinimizeAll { return await minimizeAll(language: language) }
        var wrote = false
        do {
            // Retain exactly this AX window across suspension; never silently retarget.
            let target = try access.target()
            if action == .windowMinimize {
                guard target.canSet(.minimized) else { return .failed(reason: fail) }
                try Task.checkCancellation()
                wrote = true; try target.setMinimized(true)
                for _ in 0..<10 {
                    if try target.readMinimized() { return .done(summary: actionText(language, "Вікно згорнуто.", "Window minimized.")) }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
            } else {
                guard [.windowMaximize, .windowLeftHalf, .windowRightHalf].contains(action),
                      target.canSet(.position), target.canSet(.size) else { return .failed(reason: fail) }
                let desired = WindowGeometry.destination(action, visibleFrame: target.visibleFrame)
                guard desired.width > 0, desired.height > 0 else { return .failed(reason: fail) }
                try Task.checkCancellation()
                wrote = true; try target.setSize(desired.size)
                try Task.checkCancellation()
                try target.setPosition(desired.origin)
                // Some applications constrain a resize at the original location.
                try Task.checkCancellation()
                try target.setSize(desired.size)
                for _ in 0..<10 {
                    if WindowGeometry.close(try target.readFrame(), desired) {
                        return .done(summary: actionText(language, "Вікно розташовано.", "Window arranged."))
                    }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        } catch { /* A write may have completed before cancellation/readback failure. */ }
        return wrote ? .partial(summary: actionText(language, "Вікно могло змінитися частково.", "The window may have changed partially."), details: fail) : .failed(reason: fail)
    }

    /// Minimizes every window it can and reports the count it saw minimized.
    private func minimizeAll(language: String) async -> CommandOutcome {
        let targets = access.allTargets().filter { $0.canSet(.minimized) && (try? $0.readMinimized()) == false }
        guard !targets.isEmpty else {
            return .done(summary: actionText(language, "Відкритих вікон для згортання немає.", "There are no open windows to minimize."))
        }
        var wrote = 0
        for target in targets {
            guard !Task.isCancelled else { break }
            if (try? target.setMinimized(true)) != nil { wrote += 1 }
        }
        guard wrote > 0 else {
            return Task.isCancelled ? .failed(reason: actionText(language, "Запит скасовано.", "Request cancelled."))
                : .failed(reason: actionText(language, "Не вдалося згорнути вікна.", "Unable to minimize the windows."))
        }
        var confirmed = 0
        for _ in 0..<10 {
            confirmed = targets.filter { (try? $0.readMinimized()) == true }.count
            if confirmed == targets.count { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if confirmed == targets.count {
            return .done(summary: actionText(language, "Згорнуто вікон: \(confirmed).", "Minimized \(confirmed) windows."))
        }
        return .partial(summary: actionText(language, "Згорнуто вікон: \(confirmed) з \(targets.count).", "Minimized \(confirmed) of \(targets.count) windows."),
                        details: actionText(language, "Деякі вікна не підтримують згортання.", "Some windows do not support minimizing."))
    }
}

@MainActor struct MacWindowAccess: WindowAccess {
    var trusted: Bool { AXIsProcessTrusted() }
    func target() throws -> WindowTarget {
        guard trusted, let pid = Self.frontApplicationPID() else { throw DeviceActionError.unavailable }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { throw DeviceActionError.unavailable }
        let window = value as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.25)
        var fullScreen: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullScreen) == .success,
           let fullScreen, CFGetTypeID(fullScreen) == CFBooleanGetTypeID(), CFBooleanGetValue((fullScreen as! CFBoolean)) {
            throw DeviceActionError.unsupported
        }
        let result = MacWindowTarget(window)
        let current = try result.readFrame()
        guard let primary = NSScreen.screens.first else { throw DeviceActionError.unavailable }
        let areas = NSScreen.screens.map { WindowGeometry.axFrame(fromAppKit: $0.visibleFrame, primaryTop: primary.frame.maxY) }
        guard let best = areas.max(by: { $0.intersection(current).area < $1.intersection(current).area }) else { throw DeviceActionError.unavailable }
        result.visibleFrame = best
        return result
    }
}
extension MacWindowAccess {
    /// The front application, or, when Jarvis itself is in front (the owner
    /// was looking at it), the application whose window is right behind it.
    /// Jarvis's own window is never a target.
    static func frontApplicationPID() -> pid_t? {
        let own = ProcessInfo.processInfo.processIdentifier
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != own { return app.processIdentifier }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != own,
                  NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular else { continue }
            return pid
        }
        return nil
    }

    func allTargets() -> [WindowTarget] {
        guard trusted else { return [] }
        let own = ProcessInfo.processInfo.processIdentifier
        var result: [WindowTarget] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != own && !app.isHidden {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 0.25)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }
            for window in windows.prefix(40) {
                AXUIElementSetMessagingTimeout(window, 0.25)
                var subrole: CFTypeRef?
                guard AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole) == .success,
                      (subrole as? String) == (kAXStandardWindowSubrole as String) else { continue }
                // Full-screen windows cannot be minimized.
                var fullScreen: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullScreen) == .success,
                   (fullScreen as? Bool) == true { continue }
                result.append(MacWindowTarget(window))
            }
            if result.count >= 120 { break }
        }
        return result
    }
}
private extension CGRect { var area: CGFloat { isNull ? 0 : width * height } }

@MainActor private final class MacWindowTarget: WindowTarget {
    let window: AXUIElement
    var visibleFrame: CGRect = .zero
    init(_ window: AXUIElement) { self.window = window }
    private func key(_ attribute: WindowAttribute) -> CFString {
        switch attribute { case .position: return kAXPositionAttribute as CFString
        case .size: return kAXSizeAttribute as CFString
        case .minimized: return kAXMinimizedAttribute as CFString }
    }
    func canSet(_ attribute: WindowAttribute) -> Bool {
        var yes = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(window, key(attribute), &yes) == .success && yes.boolValue
    }
    private func read(_ attribute: WindowAttribute) throws -> CFTypeRef {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, key(attribute), &value) == .success, let value else { throw DeviceActionError.unavailable }
        return value
    }
    func readFrame() throws -> CGRect {
        let p = try read(.position), s = try read(.size)
        guard CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { throw DeviceActionError.unsupported }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { throw DeviceActionError.unsupported }
        return CGRect(origin: point, size: size)
    }
    func readMinimized() throws -> Bool {
        let value = try read(.minimized)
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else { throw DeviceActionError.unsupported }
        return CFBooleanGetValue((value as! CFBoolean))
    }
    func setPosition(_ point: CGPoint) throws {
        var value = point
        guard let ax = AXValueCreate(.cgPoint, &value) else { throw DeviceActionError.unsupported }
        try set(.position, ax)
    }
    func setSize(_ size: CGSize) throws {
        var value = size
        guard let ax = AXValueCreate(.cgSize, &value) else { throw DeviceActionError.unsupported }
        try set(.size, ax)
    }
    func setMinimized(_ value: Bool) throws { try set(.minimized, value ? kCFBooleanTrue : kCFBooleanFalse) }
    private func set(_ attribute: WindowAttribute, _ value: CFTypeRef) throws {
        try Task.checkCancellation()
        guard AXUIElementSetAttributeValue(window, key(attribute), value) == .success else { throw DeviceActionError.writeFailed }
    }
}
