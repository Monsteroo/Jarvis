import AppKit
import Carbon

private let hotKeySignature: OSType = 0x4A525653 // JRVS

extension JarvisApp {
    // MARK: Hotkeys

    func registerHotKey() {
        var events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr, identifier.signature == hotKeySignature else { return OSStatus(eventNotHandledErr) }
            let app = Unmanaged<JarvisApp>.fromOpaque(userData).takeUnretainedValue()
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            if identifier.id == 1 { pressed ? app.keyDown() : app.keyUp() }
            if (identifier.id == 2 || identifier.id == 3) && pressed {
                if app.store.machine.speaking && !app.store.requestActivity.active { app.stopSpeaking() } else { app.cancelSession(message: "Скасовано. Запис зупинено, результат відкинуто.") }
            }
            return noErr
        }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard handlerStatus == noErr else { store.hotKeyAvailable = false; return }
        store.hotKeyAvailable = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey),
            EventHotKeyID(signature: hotKeySignature, id: 1), GetApplicationEventTarget(), 0, &hotKey) == noErr
    }

    func enableEscape() {
        guard escapeKey == nil else { return }
        let result = RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: hotKeySignature, id: 2),
                            GetApplicationEventTarget(), 0, &escapeKey)
        let chordResult = RegisterEventHotKey(UInt32(kVK_Escape), UInt32(controlKey | optionKey),
            EventHotKeyID(signature: hotKeySignature, id: 3), GetApplicationEventTarget(), 0, &escapeChord)
        store.escapeUnavailable = result != noErr && chordResult != noErr
    }

    func disableEscape() {
        guard !store.canCancel else { enableEscape(); return }
        if let escapeKey { UnregisterEventHotKey(escapeKey) }
        escapeKey = nil
        if let escapeChord { UnregisterEventHotKey(escapeChord) }
        escapeChord = nil
    }
}
