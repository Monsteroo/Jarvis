import AppKit
import AVFoundation
import Carbon

/// All inference and destruction run on one queue; cancellation is the only
/// concurrent bridge call and uses the bridge's atomic cancellation flag.
final class LocalSpeech {
    private let queue = DispatchQueue(label: "jarvis.inference", qos: .userInitiated)
    private let lock = NSLock()
    private var context: UnsafeMutableRawPointer?
    private var generation = 0
    private var closing = false

    func load(path: String, completion: @escaping (Bool) -> Void) {
        cancel()
        lock.lock()
        let ticket = generation
        lock.unlock()
        queue.async {
            self.lock.lock()
            if let previous = self.context { jv_free(previous) }
            self.context = nil
            self.lock.unlock()
            let context = path.withCString { jv_create($0) }
            self.lock.lock()
            self.context = context
            let closing = self.closing
            self.lock.unlock()
            DispatchQueue.main.async {
                self.lock.lock()
                let valid = ticket == self.generation
                self.lock.unlock()
                if !closing && valid { completion(context != nil) }
            }
        }
    }

    func transcribe(_ samples: [Float], language: String, completion: @escaping (String?, Double) -> Void) {
        lock.lock()
        let ticket = generation
        lock.unlock()
        queue.async {
            self.lock.lock()
            guard !self.closing, ticket == self.generation, let context = self.context else {
                self.lock.unlock()
                return
            }
            jv_reset_cancel(context)
            self.lock.unlock()
            let start = ProcessInfo.processInfo.systemUptime
            var output = [CChar](repeating: 0, count: 65_536)
            let result = samples.withUnsafeBufferPointer { audio in
                language.withCString { lang in
                    jv_transcribe(context, audio.baseAddress, Int32(audio.count), lang, &output, Int32(output.count))
                }
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            let text = result == 1 ? "" : (result == 0 ? String(cString: output).trimmingCharacters(in: .whitespacesAndNewlines) : nil)
            DispatchQueue.main.async {
                self.lock.lock()
                let valid = !self.closing && ticket == self.generation
                self.lock.unlock()
                if valid { completion(text, elapsed) }
            }
        }
    }

    func cancel() {
        lock.lock()
        generation += 1
        if let context { jv_cancel(context) }
        lock.unlock()
    }

    func close() {
        lock.lock()
        closing = true
        generation += 1
        if let context { jv_cancel(context) }
        lock.unlock()
        queue.async {
            self.lock.lock()
            if let context = self.context { jv_free(context) }
            self.context = nil
            self.lock.unlock()
        }
    }
}

private let hotKeySignature: OSType = 0x4A525653 // JRVS

final class JarvisApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let status = NSTextField(wrappingLabelWithString: "Завантаження локальної моделі…")
    private let timing = NSTextField(labelWithString: "Звук залишається в оперативній пам’яті цього Mac.")
    private let transcript = NSTextView()
    private let enableButton = NSButton(title: "Увімкнути мікрофон", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Скасувати", target: nil, action: nil)
    private let copyButton = NSButton(title: "Копіювати текст", target: nil, action: nil)
    private let language = NSPopUpButton(frame: .zero, pullsDown: false)
    private let model = NSPopUpButton(frame: .zero, pullsDown: false)
    private var modelLoading = true
    private let audio = AudioCapture()
    private let speech = LocalSpeech()
    private var gate = CaptureGate()
    private var enabled = false
    private var modelReady = false
    private var processing = false
    private var permissionPending = false
    private var hotKey: EventHotKeyRef?
    private var escapeKey: EventHotKeyRef?
    private var escapeChord: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var timeout: Timer?
    private var clock: Timer?
    private var started = 0.0
    private var observers: [NSObjectProtocol] = []
    private var hotKeyAvailable = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeWindow()
        registerHotKey()
        audio.onLimit = { [weak self] in self?.finishRecording(timedOut: true) }
        audio.onFailure = { [weak self] error in
            guard let self, self.gate.recording else { return }
            self.cancelSession(message: error.localizedDescription)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.cancelSession(message: "Запис скасовано перед сном Mac.")
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.cancelSession(message: "Запис скасовано: сеанс Mac неактивний.")
        })
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // A release can be lost while the session sleeps or switches users.
                _ = self?.gate.release()
            })
        }
        loadSelectedModel()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 480),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Jarvis — локальний голос"
        window.minSize = NSSize(width: 570, height: 390)
        window.center()
        let heading = NSTextField(labelWithString: "Jarvis")
        heading.font = .systemFont(ofSize: 30, weight: .semibold)
        let hint = NSTextField(wrappingLabelWithString: "Утримуйте ⌃⌥Пробіл, говоріть і відпустіть для розпізнавання. Esc — скасувати. Максимум 30 секунд.")
        status.font = .systemFont(ofSize: 14, weight: .medium)
        timing.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timing.textColor = .secondaryLabelColor
        language.addItems(withTitles: ["Українська", "Русский", "English", "Автовизначення"])
        language.toolTip = "Мова розпізнавання"
        language.setAccessibilityLabel("Мова розпізнавання")
        model.addItems(withTitles: ["base", "small"])
        model.target = self
        model.action = #selector(loadSelectedModel)
        model.setAccessibilityLabel("Локальна модель")
        enableButton.target = self
        enableButton.action = #selector(toggleMicrophone)
        copyButton.target = self
        copyButton.action = #selector(copyTranscript)
        copyButton.isEnabled = false
        cancelButton.target = self
        cancelButton.action = #selector(cancelFromButton)
        cancelButton.isEnabled = false
        let controls = NSStackView(views: [enableButton, language, copyButton])
        controls.orientation = .horizontal
        controls.spacing = 12
        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.isRichText = false
        transcript.font = .systemFont(ofSize: 18)
        transcript.textContainerInset = NSSize(width: 14, height: 14)
        transcript.autoresizingMask = [.width]
        transcript.isVerticallyResizable = true
        transcript.isHorizontallyResizable = false
        transcript.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = transcript
        let settings = NSStackView(views: [NSTextField(labelWithString: "Модель:"), model, cancelButton])
        settings.spacing = 10
        let stack = NSStackView(views: [heading, hint, controls, settings, status, scroll, timing])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -24),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func loadSelectedModel() {
        modelReady = false
        modelLoading = true
        model.isEnabled = false
        status.stringValue = "Завантаження локальної моделі…"
        let root = Bundle.main.object(forInfoDictionaryKey: "JarvisProjectRoot") as? String
            ?? FileManager.default.currentDirectoryPath
        let name = model.indexOfSelectedItem == 1 ? "small" : "base"
        speech.load(path: root + "/.runtime/models/ggml-" + name + ".bin") { [weak self] ready in
            guard let self else { return }
            self.modelLoading = false
            self.modelReady = ready
            self.model.isEnabled = true
            self.updateIdleStatus()
        }
    }

    private func registerHotKey() {
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
            if (identifier.id == 2 || identifier.id == 3) && pressed { app.cancelSession(message: "Скасовано. Мікрофон вимкнено.") }
            return noErr
        }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard handlerStatus == noErr else { return }
        hotKeyAvailable = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey),
            EventHotKeyID(signature: hotKeySignature, id: 1), GetApplicationEventTarget(), 0, &hotKey) == noErr
    }

    private func enableEscape() {
        guard escapeKey == nil else { return }
        let result = RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: hotKeySignature, id: 2),
                            GetApplicationEventTarget(), 0, &escapeKey)
        let chordResult = RegisterEventHotKey(UInt32(kVK_Escape), UInt32(controlKey | optionKey),
            EventHotKeyID(signature: hotKeySignature, id: 3), GetApplicationEventTarget(), 0, &escapeChord)
        if result != noErr || chordResult != noErr {
            status.stringValue += " Esc недоступний — використайте кнопку «Скасувати»."
        }
    }

    private func disableEscape() {
        if let escapeKey { UnregisterEventHotKey(escapeKey) }
        escapeKey = nil
        if let escapeChord { UnregisterEventHotKey(escapeChord) }
        escapeChord = nil
    }

    @objc private func toggleMicrophone() {
        if enabled {
            enabled = false
            enableButton.title = "Увімкнути мікрофон"
            cancelSession(message: "Мікрофон вимкнено.")
            return
        }
        guard !permissionPending else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            enabled = true
            enableButton.title = "Вимкнути мікрофон"
            updateIdleStatus()
        case .notDetermined:
            permissionPending = true
            enableButton.isEnabled = false
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.permissionPending = false
                    self.enableButton.isEnabled = true
                    self.enabled = granted
                    self.enableButton.title = granted ? "Вимкнути мікрофон" : "Увімкнути мікрофон"
                    self.updateIdleStatus()
                    // Deliberately never call keyDown here, even if the key is held.
                }
            }
        default:
            status.stringValue = "Дозвольте мікрофон для Jarvis у Системних параметрах → Конфіденційність і безпека → Мікрофон."
        }
    }

    private func updateIdleStatus() {
        guard !gate.recording && !processing else { return }
        if !hotKeyAvailable {
            status.stringValue = "Не вдалося зареєструвати ⌃⌥Пробіл. Закрийте інший Jarvis або програму з цим скороченням."
        } else if modelLoading {
            status.stringValue = "Завантаження локальної моделі…"
        } else if !modelReady {
            status.stringValue = "Локальна модель недоступна. Перевірте встановлення або виберіть іншу модель."
        } else if enabled {
            status.stringValue = "Готово. Мікрофон увімкнеться лише під час утримання ⌃⌥Пробіл."
        } else if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
            status.stringValue = "Доступ до мікрофона заборонено. Надайте його в Системних параметрах."
        } else {
            status.stringValue = "Модель готова. Натисніть «Увімкнути мікрофон», щоб дозволити голосове введення."
        }
    }

    private func keyDown() {
        let authorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        guard gate.press(enabled: enabled, authorized: authorized, ready: modelReady && !processing && hotKeyAvailable) else { return }
        do { try audio.start() } catch {
            gate.cancel()
            status.stringValue = error.localizedDescription
            return
        }
        cancelButton.isEnabled = true
        started = ProcessInfo.processInfo.systemUptime
        language.isEnabled = false
        model.isEnabled = false
        status.stringValue = "● Слухаю… Відпустіть ⌃⌥Пробіл для розпізнавання."
        timing.stringValue = "Запис: 0,0 с / 30 с"
        enableEscape()
        clock = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let elapsed = ProcessInfo.processInfo.systemUptime - self.started
            self.timing.stringValue = String(format: "Запис: %.1f с / 30 с", elapsed)
        }
        timeout = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            self?.finishRecording(timedOut: true)
        }
        if let clock { RunLoop.main.add(clock, forMode: .common) }
        if let timeout { RunLoop.main.add(timeout, forMode: .common) }
    }

    private func keyUp() {
        let wasRecording = gate.release()
        if wasRecording { finishRecording(timedOut: false) }
    }

    private func finishRecording(timedOut: Bool) {
        guard clock != nil else { return }
        let releasedAt = ProcessInfo.processInfo.systemUptime
        gate.cancel()
        stopTimers()
        let samples = audio.stop()
        let duration = Double(samples.count) / 16_000
        guard duration >= 0.25 else {
            language.isEnabled = true
            model.isEnabled = true
            cancelButton.isEnabled = false
            disableEscape()
            status.stringValue = "Запис надто короткий. Утримуйте ⌃⌥Пробіл і скажіть фразу."
            return
        }
        processing = true
        let code = ["uk", "ru", "en", "auto"][max(0, language.indexOfSelectedItem)]
        status.stringValue = timedOut ? "Досягнуто 30 с. Мікрофон вимкнено, розпізнаю…" : "Мікрофон вимкнено. Розпізнаю локально…"
        timing.stringValue = String(format: "Аудіо: %.1f с · розпізнавання…", duration)
        speech.transcribe(samples, language: code) { [weak self] text, elapsed in
            guard let self else { return }
            let responseTime = ProcessInfo.processInfo.systemUptime - releasedAt
            self.processing = false
            self.cancelButton.isEnabled = false
            self.language.isEnabled = true
            self.model.isEnabled = true
            self.disableEscape()
            if let text {
                self.transcript.string = text
                self.copyButton.isEnabled = !text.isEmpty
                self.status.stringValue = text.isEmpty ? "Мовлення не знайдено. Спробуйте ще раз." : "Готово. Утримуйте ⌃⌥Пробіл для наступної фрази."
            } else {
                self.status.stringValue = "Помилка локального розпізнавання. Спробуйте ще раз."
            }
            self.timing.stringValue = String(format: "Аудіо: %.1f с · Whisper: %.2f с · відповідь: %.2f с", duration, elapsed, responseTime)
            self.timing.toolTip = "Відповідь — час від відпускання клавіші (або ліміту 30 с) до появи тексту."
        }
    }

    private func stopTimers() {
        clock?.invalidate()
        timeout?.invalidate()
        clock = nil
        timeout = nil
    }

    @objc private func cancelFromButton() {
        cancelSession(message: "Скасовано. Мікрофон вимкнено.")
    }

    private func cancelSession(message: String) {
        gate.cancel()
        stopTimers()
        audio.stop()
        if !modelLoading { speech.cancel() }
        processing = false
        cancelButton.isEnabled = false
        language.isEnabled = true
        model.isEnabled = !modelLoading
        disableEscape()
        status.stringValue = message
        timing.stringValue = "Звук не збережено на диск."
    }

    @objc private func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript.string, forType: .string)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        cancelSession(message: "Завершення…")
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        speech.close()
    }
}

@main
struct JarvisMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = JarvisApp()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
