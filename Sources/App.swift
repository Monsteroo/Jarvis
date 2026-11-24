import AppKit
import AVFoundation
import Carbon
import Combine
import SwiftUI

final class JarvisApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = VoiceStore()
    let level = LevelStore()
    lazy var meter = AudioMeterPump { [weak self] in
        self?.level.value = $0
        self?.debugLevel($0)
    }
    /// Opt-in developer check (JARVIS_DEBUG_LEVELS=1): prints envelope numbers
    /// twice a second to stderr. Numbers only — never audio samples.
    let debugLevels = ProcessInfo.processInfo.environment["JARVIS_DEBUG_LEVELS"] == "1"
    /// Opt-in wake pipeline trace (JARVIS_DEBUG_WAKE=1): events, durations and the
    /// first recognised word of a segment (to tune the address check); never audio
    /// or the rest of the text.
    let debugWake = ProcessInfo.processInfo.environment["JARVIS_DEBUG_WAKE"] == "1"
    func wakeTrace(_ text: String) {
        guard debugWake else { return }
        FileHandle.standardError.write(("app " + text + "\n").data(using: .utf8)!)
    }
    var debugPeak: Float = 0
    var debugStamp = 0.0
    var window: NSWindow!
    var hud: HUDPanel!
    var statusItem: NSStatusItem?
    var hudHide: Timer?
    var stateSink: AnyCancellable?
    let diagnostic = DiagnosticCapture()
    let audio = AudioCapture()
    let speech = LocalSpeech()
    lazy var wake = WakeListener { [weak self] in self?.wakeEvent($0) }
    /// Parakeet screening of speech segments while wake is armed (user
    /// decision, 10 Nov 2026). One in flight, at most one pending (the newest).
    struct Segment { let samples: [Float]; let end: Int; let epoch: Int; let heardAt: Double }
    var screening = WakeScreeningQueue<Segment>()
    var wakeActivationRequest: UUID?
    enum RecordSource { case ptt, wake }
    var source: RecordSource = .ptt
    var wakePrefixConfirmed = false
    /// Wake monitoring was running before sleep / session switch.
    var resumeWakeOnWake = false
    var gate = CaptureGate()
    var turn: Int?
    var hotKey: EventHotKeyRef?
    var escapeKey: EventHotKeyRef?
    var escapeChord: EventHotKeyRef?
    var eventHandler: EventHandlerRef?
    var timeout: Timer?
    var clock: Timer?
    var started = 0.0
    var observers: [(NotificationCenter, NSObjectProtocol)] = []
    var prompts: [Prompt] = []
    var measurementLog: MeasurementLog?
    var progress: MeasurementProgress?

    var projectRoot: String {
        Bundle.main.object(forInfoDictionaryKey: "JarvisProjectRoot") as? String ?? FileManager.default.currentDirectoryPath
    }
    let modelNames = ["parakeet-uk-v3", "small", "base"]
    var modelName: String { modelNames[store.modelIndex] }
    var recordingLimit: Int { modelName == "parakeet-uk-v3" ? 15 : 30 }
    var languageCode: String { ["uk", "en"][store.languageIndex] }

    var actions: VoiceActions {
        VoiceActions(
            toggleMicrophone: { [weak self] in self?.toggleMicrophone() },
            toggleWake: { [weak self] in self?.toggleWake() },
            cancel: { [weak self] in self?.cancelSession(message: "Скасовано. Запис зупинено, результат відкинуто.") },
            copy: { [weak self] in self?.copyTranscript() },
            setLanguage: { [weak self] in self?.setLanguage($0) },
            setModel: { [weak self] in self?.setModel($0) },
            toggleDiagnostic: { [weak self] in self?.toggleDiagnostic() },
            revealDiagnostic: { [weak self] in self?.revealDiagnostic() },
            setMeasuring: { [weak self] in self?.setMeasuring($0) },
            skipPrompt: { [weak self] in self?.skipPrompt() },
            previewVoice: { [weak self] in self?.previewVoice($0) },
            saveCloudKey: { [weak self] in self?.saveCloudKey($0) },
            deleteCloudKey: { [weak self] in self?.deleteCloudKey() },
            saveOpenAIKey: { [weak self] in self?.saveOpenAIKey($0) },
            deleteOpenAIKey: { [weak self] in self?.deleteOpenAIKey() },
            openMicrophoneSettings: {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            },
            revealConversations: { [weak self] in self?.revealConversations() },
            clearConversations: { [weak self] in self?.clearConversations() })
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        store.recordLimit = recordingLimit
        makeMainMenu()
        makeWindow()
        makeHUD()
        makeStatusItem()
        registerHotKey()
        voice.onFinish = { [weak self] in self?.speechEnded() }
        voice.onCloudResult = { [weak self] in self?.cloudResult($0, characters: $1, seconds: $2) }
        store.refreshCloudUsage()
        store.agentRuntimeReady = FileManager.default.isExecutableFile(atPath: gooseExecutable.path)
            && FileManager.default.isExecutableFile(atPath: helperExecutable.path)
        loadKeys()
        conversationLog.prune()
        store.loadVoices()
        audio.onLimit = { [weak self] in self?.finishRecording(timedOut: true) }
        audio.onFailure = { [weak self] error in
            guard let self else { return }
            let wasBusy = self.store.machine.phase == .recording
            self.cancelSession(message: "")
            if wasBusy { self.store.machine.fail(message: error.localizedDescription) }
            // Wake monitoring survives an input-device switch: restart it on
            // the new device, or turn activation off with a visible reason.
            if self.store.machine.wakeEnabled { self.restartMonitoring(reason: error) }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.suspendCapture(message: "Запис скасовано перед сном Mac.") }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.suspendCapture(message: "Запис скасовано: сеанс Mac неактивний.") }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            // A release can be lost while the session sleeps or switches users.
            observe(workspace, name) { app in
                _ = app.gate.release()
                app.resumeCapture()
            }
        }
        observe(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) {
            $0.store.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        observe(NotificationCenter.default, NSWindow.didChangeOcclusionStateNotification) { app in
            app.store.mainVisible = app.window.isVisible && app.window.occlusionState.contains(.visible)
        }
        stateSink = store.$machine.removeDuplicates().sink { [weak self] machine in
            DispatchQueue.main.async { self?.stateChanged(machine) }
        }
        loadSelectedModel()
        NSApp.activate(ignoringOtherApps: true)
    }

    func debugLevel(_ value: AudioLevel) {
        guard debugLevels else { return }
        debugPeak = max(debugPeak, value.envelope)
        let now = ProcessInfo.processInfo.systemUptime
        guard now - debugStamp >= 0.5 else { return }
        debugStamp = now
        let bands = value.bands.map { String(format: "%.2f", $0) }.joined(separator: " ")
        FileHandle.standardError.write(String(format: "level phase=%@ env=%.3f max=%.3f bands=[%@]\n",
                                              "\(store.phase)", value.envelope, debugPeak, bands).data(using: .utf8)!)
        debugPeak = 0
    }

    let chime = AcknowledgmentSound()

    // Actions
    lazy var executor: ActionExecutor = MainActor.assumeIsolated {
        ActionExecutor.live(history: try? HistoryStore())
    }
    var commandTask: Task<Void, Never>?
    /// One-use token for the text field that was focused when the turn began.
    var dictationToken: UUID?
    var lastCommandText = ""
    var lastCommandTurn = 0
    // AI agent
    var agentParts: (agent: BudgetedGooseAgent, broker: AgentActionBroker, ledger: BudgetLedger, model: String)?
    var agentTask: Task<Void, Never>?
    var approval: AgentApprovalController?
    var cachedOpenAIKey: String?
    /// False until the launch-time Keychain read finishes. Until then no key
    /// is read on the main thread: a Keychain access prompt would freeze the
    /// whole app while it waits for the owner (seen 24.11.2026 after install).
    var keysLoaded = false
    // Brain
    lazy var brain = JarvisBrain(model: store.agentModel)
    /// Turn in which the brain already said something (cancels the late acknowledgment).
    var brainSpokeTurn: Int?
    var brainFirstSpeech: Double?
    var lastPrewarm = 0.0
    var acknowledgmentIndex = Int.random(in: 0..<4)
    let agentProbe = AgentTimingProbe()
    // Conversation log
    lazy var conversationLog = ConversationLog(directory: appSupport.appendingPathComponent("conversations"),
                                                       enabled: store.conversationLog)
    // Spoken replies
    let voice = SpeechOutput()
    var speechToken = 0
    /// Replies that arrived while something was still being said, in order
    /// (the acknowledgment, then the brain's streamed sentences).
    var queuedSpeech: [(text: String, language: String)] = []
    var cachedCloudKey: String?

    func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping (JarvisApp) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            if let self { handler(self) }
        }
        observers.append((center, token))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = NSMenuItem(title: "Стан: \(store.headline)", action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        let wakeItem = menuItem("Активація словом «Jarvis»", #selector(toggleWakeFromMenu))
        wakeItem.state = store.machine.wakeEnabled ? .on : .off
        wakeItem.isEnabled = !store.wakeLoading && !store.permissionPending
        menu.addItem(wakeItem)
        menu.addItem(.separator())
        menu.addItem(menuItem("Показати Jarvis", #selector(showMainWindow)))
        menu.addItem(menuItem(store.machine.microphoneEnabled ? "Вимкнути мікрофон" : "Увімкнути мікрофон", #selector(toggleMicrophoneFromMenu)))
        let cancel = menuItem("Скасувати поточний запит", #selector(cancelFromMenu))
        cancel.isEnabled = store.canCancel
        menu.addItem(cancel)
        menu.addItem(.separator())
        menu.addItem(menuItem("Завершити Jarvis", #selector(quit)))
    }

    func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    @objc func toggleMicrophoneFromMenu() { toggleMicrophone() }
    @objc func toggleWakeFromMenu() { toggleWake() }
    @objc func cancelFromMenu() { cancelSession(message: "Скасовано. Запис зупинено, результат відкинуто.") }
    @objc func quit() { NSApp.terminate(nil) }

    func stateChanged(_ machine: VoiceMachine) {
        refreshEscape()
        updateStatusIcon()
        // The detector listens only while idle with activation enabled; a
        // wake-started command switches it to endpointing by itself.
        if machine.wakeArmed && audio.isMonitoring {
            wake.setMode(.armed)
        } else if !(machine.busy && source == .wake) {
            wake.setMode(.off)
        }
        if store.requestActivity.active { showHUD(); return }
        switch machine.phase {
        case .recording, .transcribing, .speaking: showHUD()
        case .microphoneOff: hideHUD(after: 1.2)
        default: hideHUD(after: 3.5)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window.makeKeyAndOrderFront(nil) }
        return true
    }

    // MARK: Lifecycle

    /// Jarvis stays in the menu bar after the main window closes; Quit is explicit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        cancelSession(message: "")
        wake.stop()
        wake.close()
        audio.shutdown()
        meter.stop()
        hudHide?.invalidate()
        hudHide = nil
        hud.orderOut(nil)
        stateSink = nil
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
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
