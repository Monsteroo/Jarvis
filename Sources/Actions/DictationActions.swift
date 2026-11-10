import AppKit
import ApplicationServices

struct TextSnapshot: Equatable {
    let value: String
    let selection: NSRange
    func replacing(with text: String) throws -> String {
        let string = value as NSString
        guard string.length <= 32_768, selection.location >= 0, selection.length >= 0,
              selection.location <= string.length, selection.length <= string.length - selection.location,
              Range(selection, in: value) != nil else { throw DeviceActionError.unsupported }
        let units = Array(value.utf16)
        func validBoundary(_ index: Int) -> Bool {
            index == 0 || index == units.count || !((0xD800...0xDBFF).contains(units[index - 1]) && (0xDC00...0xDFFF).contains(units[index]))
        }
        guard validBoundary(selection.location), validBoundary(selection.location + selection.length) else { throw DeviceActionError.unsupported }
        return string.replacingCharacters(in: selection, with: text)
    }
}
@MainActor protocol DictationField: AnyObject {
    func isSafeAndFocused() -> Bool
    func snapshot() throws -> TextSnapshot
    func replaceSelection(_ text: String) throws
}
@MainActor protocol DictationAccess { func focusedField() throws -> DictationField }

/// Capture before recording/HUD. A token authorizes one insertion into one unchanged field.
@MainActor final class DictationActions {
    let access: DictationAccess
    private var pending: (id: UUID, field: DictationField, snapshot: TextSnapshot, expires: TimeInterval)?
    private let uptime: () -> TimeInterval
    init(access: DictationAccess, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.access = access; self.uptime = uptime
    }
    func invalidate() { pending = nil }
    func capture() throws -> UUID {
        invalidate()
        try Task.checkCancellation()
        let field = try access.focusedField()
        guard field.isSafeAndFocused() else { throw DeviceActionError.unsupported }
        let snapshot = try field.snapshot()
        _ = try snapshot.replacing(with: "")
        let id = UUID()
        pending = (id, field, snapshot, uptime() + 90)
        return id
    }
    func insert(_ text: String, token: UUID?, language: String) -> CommandOutcome {
        let fail = actionText(language, "Виберіть доступне текстове поле й повторіть диктування. Ціль могла змінитися або дозвіл Доступності відсутній.", "Select an editable text field and dictate again. The target may have changed or Accessibility permission may be missing.")
        guard let token, let target = pending, target.id == token else { return .failed(reason: fail) }
        pending = nil // One use, including all failure/cancellation paths.
        var attempted = false
        do {
            try Task.checkCancellation()
            guard target.expires >= uptime(), !text.isEmpty, text.count <= 16_000,
                  target.field.isSafeAndFocused(), try target.field.snapshot() == target.snapshot else { return .failed(reason: fail) }
            let expected = try target.snapshot.replacing(with: text)
            try Task.checkCancellation()
            // No await between identity/content validation and the single AX write.
            attempted = true
            try target.field.replaceSelection(text)
            guard try target.field.snapshot().value == expected else {
                return .partial(summary: actionText(language, "Вставлення тексту не підтверджено.", "Text insertion was not confirmed."), details: fail)
            }
            return .done(summary: actionText(language, "Текст вставлено.", "Text inserted."))
        } catch { }
        return attempted ? .partial(summary: actionText(language, "Текст міг вставитися частково.", "Text may have been inserted partially."), details: fail) : .failed(reason: fail)
    }
}

@MainActor struct MacDictationAccess: DictationAccess {
    func focusedField() throws -> DictationField {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { throw DeviceActionError.unavailable }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        let field = try MacDictationField.focused(axApp)
        AXUIElementSetMessagingTimeout(field, 0.25)
        return MacDictationField(field: field, app: axApp, pid: app.processIdentifier)
    }
}

@MainActor private final class MacDictationField: DictationField {
    let field: AXUIElement, app: AXUIElement
    let pid: pid_t
    init(field: AXUIElement, app: AXUIElement, pid: pid_t) { self.field = field; self.app = app; self.pid = pid }
    static func focused(_ app: AXUIElement) throws -> AXUIElement {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { throw DeviceActionError.unavailable }
        return value as! AXUIElement
    }
    private func read(_ key: String) throws -> CFTypeRef {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, key as CFString, &value) == .success, let value else { throw DeviceActionError.unavailable }
        return value
    }
    func isSafeAndFocused() -> Bool {
        guard AXIsProcessTrusted(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let current = try? Self.focused(app), CFEqual(current, field),
              let role = try? read(kAXRoleAttribute) as? String,
              [kAXTextFieldRole, kAXTextAreaRole].contains(role),
              let subrole = try? read(kAXSubroleAttribute) as? String,
              subrole != kAXSecureTextFieldSubrole,
              let enabled = try? read(kAXEnabledAttribute), CFGetTypeID(enabled) == CFBooleanGetTypeID(),
              CFBooleanGetValue((enabled as! CFBoolean)) else { return false }
        var writable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(field, kAXSelectedTextAttribute as CFString, &writable) == .success && writable.boolValue
    }
    func snapshot() throws -> TextSnapshot {
        guard isSafeAndFocused(), let text = try read(kAXValueAttribute) as? String else { throw DeviceActionError.unsupported }
        let raw = try read(kAXSelectedTextRangeAttribute)
        guard CFGetTypeID(raw) == AXValueGetTypeID() else { throw DeviceActionError.unsupported }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { throw DeviceActionError.unsupported }
        return TextSnapshot(value: text, selection: NSRange(location: range.location, length: range.length))
    }
    func replaceSelection(_ text: String) throws {
        try Task.checkCancellation()
        guard isSafeAndFocused() else { throw DeviceActionError.unavailable }
        guard AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, text as CFString) == .success else { throw DeviceActionError.writeFailed }
    }
}
