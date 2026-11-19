import AppKit
import AVFoundation
import Carbon
import Combine
import SwiftUI

/// All inference and destruction run on one queue; cancellation is the only
/// concurrent bridge call and uses the bridge's atomic cancellation flag.
final class LocalSpeech {
    private let queue = DispatchQueue(label: "jarvis.inference", qos: .userInitiated)
    private let lock = NSLock()
    private var context: UnsafeMutableRawPointer?
    private var parakeet: ParakeetASR?
    private var generation = 0
    /// Separate from `generation`: cancelling an utterance must never drop a
    /// pending model-load completion, or the UI would stay in "loading" forever.
    private var loadGeneration = 0
    private var closing = false

    func load(path: String, completion: @escaping (Bool) -> Void) {
        cancel()
        lock.lock()
        loadGeneration += 1
        let ticket = loadGeneration
        lock.unlock()
        queue.async {
            self.lock.lock()
            if let previous = self.context { jv_free(previous) }
            self.context = nil
            self.parakeet = nil
            self.lock.unlock()
            let isParakeet = !path.hasSuffix(".bin")
            let parakeet = isParakeet ? try? ParakeetASR(root: URL(fileURLWithPath:path)) : nil
            let context = isParakeet ? nil : path.withCString { jv_create($0) }
            self.lock.lock()
            self.context = context
            self.parakeet = parakeet
            let closing = self.closing
            self.lock.unlock()
            DispatchQueue.main.async {
                self.lock.lock()
                let valid = ticket == self.loadGeneration && !self.closing
                self.lock.unlock()
                if !closing && valid { completion(context != nil || parakeet != nil) }
            }
        }
    }

    func transcribe(_ samples: [Float], language: String, completion: @escaping (String?, Double) -> Void) {
        lock.lock()
        let ticket = generation
        lock.unlock()
        queue.async {
            self.lock.lock()
            guard !self.closing, ticket == self.generation, self.context != nil || self.parakeet != nil else {
                self.lock.unlock()
                return
            }
            let context = self.context
            let parakeet = self.parakeet
            if let context { jv_reset_cancel(context) }
            parakeet?.resetCancellation()
            self.lock.unlock()
            let start = ProcessInfo.processInfo.systemUptime
            let text: String?
            if let parakeet {
                text = try? parakeet.transcribe(samples,language:language)
            } else if let context {
                var output = [CChar](repeating: 0, count: 65_536)
                let result = samples.withUnsafeBufferPointer { audio in
                    language.withCString { lang in
                        jv_transcribe(context, audio.baseAddress, Int32(audio.count), lang, &output, Int32(output.count))
                    }
                }
                text = result == 1 ? "" : (result == 0 ? String(cString:output).trimmingCharacters(in:.whitespacesAndNewlines) : nil)
            } else { text = nil }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            DispatchQueue.main.async {
                self.lock.lock()
                let valid = !self.closing && ticket == self.generation
                self.lock.unlock()
                if valid { completion(text, elapsed) }
            }
        }
    }

    /// Runs one throwaway Parakeet pass on a quiet synthetic tone so model
    /// weights are paged in before the first real command (a cold first pass
    /// measured 3.5–5.7 s). Silence would be skipped by the energy check, so
    /// the signal must not be silent. Queued: a real command waits behind it.
    func warmUp(completion: @escaping (Double) -> Void) {
        queue.async {
            self.lock.lock()
            let parakeet = self.closing ? nil : self.parakeet
            parakeet?.resetCancellation()
            self.lock.unlock()
            guard let parakeet else { return }
            let tone = (0..<16_000).map { Float(0.05 * sin(Double($0) * 0.07)) }
            let start = ProcessInfo.processInfo.systemUptime
            _ = try? parakeet.transcribe(tone, language: "uk")
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            DispatchQueue.main.async { completion(elapsed) }
        }
    }

    func cancel() {
        lock.lock()
        generation += 1
        if let context { jv_cancel(context) }
        parakeet?.cancel()
        lock.unlock()
    }

    /// Wake screening: transcribes one speech segment with Parakeet without
    /// touching turn generations, so it never drops or replaces a command
    /// result. Runs on the same serial queue (after any queued command).
    /// Always completes on main; nil when Parakeet is not the loaded model,
    /// on failure, or when a turn cancel interrupted it.
    func screen(_ samples: [Float], language: String, completion: @escaping (String?, Double) -> Void) {
        queue.async {
            self.lock.lock()
            let parakeet = self.closing ? nil : self.parakeet
            parakeet?.resetCancellation()
            self.lock.unlock()
            let start = ProcessInfo.processInfo.systemUptime
            let text = parakeet.flatMap { try? $0.transcribe(samples, language: language) }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            DispatchQueue.main.async { completion(text, elapsed) }
        }
    }

    func close() {
        lock.lock()
        closing = true
        generation += 1
        if let context { jv_cancel(context) }
        parakeet?.cancel()
        lock.unlock()
        queue.async {
            self.lock.lock()
            if let context = self.context { jv_free(context) }
            self.context = nil
            self.parakeet = nil
            self.lock.unlock()
        }
    }
}


private let hotKeySignature: OSType = 0x4A525653 // JRVS

/// Floating HUD that never becomes key, so dictation targets keep focus.
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Mic-off and cancel must react to the first click, even in an inactive window or the non-key HUD.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class JarvisApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = VoiceStore()
    private let level = LevelStore()
    private lazy var meter = AudioMeterPump { [weak self] in
        self?.level.value = $0
        self?.debugLevel($0)
    }
    /// Opt-in developer check (JARVIS_DEBUG_LEVELS=1): prints envelope numbers
    /// twice a second to stderr. Numbers only — never audio samples.
    private let debugLevels = ProcessInfo.processInfo.environment["JARVIS_DEBUG_LEVELS"] == "1"
    /// Opt-in wake pipeline trace (JARVIS_DEBUG_WAKE=1): events and durations only, never text or audio.
    private let debugWake = ProcessInfo.processInfo.environment["JARVIS_DEBUG_WAKE"] == "1"
    private func wakeTrace(_ text: String) {
        guard debugWake else { return }
        FileHandle.standardError.write(("app " + text + "\n").data(using: .utf8)!)
    }
    private var debugPeak: Float = 0
    private var debugStamp = 0.0
    private var window: NSWindow!
    private var hud: HUDPanel!
    private var statusItem: NSStatusItem?
    private var hudHide: Timer?
    private var stateSink: AnyCancellable?
    private let diagnostic = DiagnosticCapture()
    private let audio = AudioCapture()
    private let speech = LocalSpeech()
    private lazy var wake = WakeListener { [weak self] in self?.wakeEvent($0) }
    /// Parakeet screening of speech segments while wake is armed (user
    /// decision, 10 Nov 2026). One in flight, at most one pending (the newest).
    private struct Segment { let samples: [Float]; let end: Int; let epoch: Int; let heardAt: Double }
    private var screening = WakeScreeningQueue<Segment>()
    private var wakeActivationRequest: UUID?
    private enum RecordSource { case ptt, wake }
    private var source: RecordSource = .ptt
    private var wakePrefixConfirmed = false
    /// Wake monitoring was running before sleep / session switch.
    private var resumeWakeOnWake = false
    private var gate = CaptureGate()
    private var turn: Int?
    private var hotKey: EventHotKeyRef?
    private var escapeKey: EventHotKeyRef?
    private var escapeChord: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var timeout: Timer?
    private var clock: Timer?
    private var started = 0.0
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var prompts: [Prompt] = []
    private var measurementLog: MeasurementLog?
    private var progress: MeasurementProgress?

    private var projectRoot: String {
        Bundle.main.object(forInfoDictionaryKey: "JarvisProjectRoot") as? String ?? FileManager.default.currentDirectoryPath
    }
    private let modelNames = ["parakeet-uk-v3", "small", "base"]
    private var modelName: String { modelNames[store.modelIndex] }
    private var recordingLimit: Int { modelName == "parakeet-uk-v3" ? 15 : 30 }
    private var languageCode: String { ["uk", "en"][store.languageIndex] }

    private var actions: VoiceActions {
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
        store.hasCloudKey = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"] != nil
            || KeychainSecret.read(KeychainSecret.elevenLabs) != nil
        store.refreshCloudUsage()
        store.hasOpenAIKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil
            || KeychainSecret.read(KeychainSecret.openAI) != nil
        store.agentRuntimeReady = FileManager.default.isExecutableFile(atPath: gooseExecutable.path)
            && FileManager.default.isExecutableFile(atPath: helperExecutable.path)
        if store.hasOpenAIKey, let parts = try? agentComponents() { agentParts = parts; refreshAgentBudget() }
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

    private func debugLevel(_ value: AudioLevel) {
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

    private let chime = AcknowledgmentSound()

    // MARK: Actions (ChatGPT's ActionExecutor, one instance)

    private lazy var executor: ActionExecutor = MainActor.assumeIsolated {
        ActionExecutor.live(history: try? HistoryStore())
    }
    private var commandTask: Task<Void, Never>?
    /// One-use token for the text field that was focused when the turn began.
    private var dictationToken: UUID?

    /// Before the HUD appears: remember the focused text field for dictation.
    private func captureFocus() {
        dictationToken = MainActor.assumeIsolated { try? executor.captureDictationTarget() }
        wakeTrace("focus field=\(dictationToken != nil)") // a flag only, no app names or text
    }

    private func refreshEscape() {
        if store.canCancel { enableEscape() } else { disableEscape() }
    }
    private func beginRequest(turn id: Int, phase: RequestActivity.Phase) {
        store.requestActivity.begin(turn: id, phase: phase)
        refreshEscape()
        showHUD()
    }
    private func finishRequest(turn id: Int) {
        store.requestActivity.finish(turn: id)
        refreshEscape()
        if !store.canCancel { hideHUD(after: 3.5) }
    }

    private func cancelCommand() {
        commandTask?.cancel()
        commandTask = nil
        cancelAgent()
        store.requestActivity.cancel()
        refreshEscape()
    }

    /// Runs a recognised command through the typed executor and reports the
    /// real outcome. A newer turn or cancel makes a late result invisible.
    private func runCommand(_ text: String, turn id: Int, language: String) {
        cancelCommand()
        guard !text.isEmpty else { return }
        beginRequest(turn: id, phase: .command)
        let token = dictationToken
        dictationToken = nil
        lastCommandText = text
        lastCommandTurn = id
        store.stages.action = .active
        store.stages.actionNote = nil
        let executor = self.executor
        let started = ProcessInfo.processInfo.systemUptime
        commandTask = Task { @MainActor [weak self] in
            let outcome = await executor.handle(text, language: language, dictationToken: token)
            guard let self, !Task.isCancelled, self.store.machine.turn == id, !self.store.machine.busy else { return }
            self.commandTask = nil
            self.present(outcome, turn: id, language: language, seconds: ProcessInfo.processInfo.systemUptime - started)
        }
    }

    private var lastCommandText = ""
    private var lastCommandTurn = 0

    // MARK: AI agent (Goose + OpenAI; any action needs native one-time approval)

    private var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Jarvis")
    }
    /// Both executables come from this app bundle only, never from settings or the model.
    private var gooseExecutable: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/goose-acp") }
    private var helperExecutable: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/JarvisMCPHelper") }
    private var agentParts: (agent: BudgetedGooseAgent, broker: AgentActionBroker, ledger: BudgetLedger, model: String)?
    private var agentTask: Task<Void, Never>?
    private var approval: AgentApprovalController?
    private var cachedOpenAIKey: String?

    private func openAIKey() -> String? {
        if cachedOpenAIKey == nil {
            cachedOpenAIKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? KeychainSecret.read(KeychainSecret.openAI)
        }
        return cachedOpenAIKey.flatMap { $0.isEmpty ? nil : $0 }
    }

    private var agentAvailable: Bool {
        store.agentEnabled && FileManager.default.isExecutableFile(atPath: gooseExecutable.path)
            && FileManager.default.isExecutableFile(atPath: helperExecutable.path) && openAIKey() != nil
    }

    /// One broker/ledger/agent for the app; rebuilt only when the model changes.
    private func agentComponents() throws -> (agent: BudgetedGooseAgent, broker: AgentActionBroker, ledger: BudgetLedger, model: String) {
        if let parts = agentParts, parts.model == store.agentModel { return parts }
        let runner = MainActor.assumeIsolated { LocalTypedActionRunner(executor) }
        let broker = agentParts?.broker ?? AgentActionBroker(executor: runner)
        let ledger = try agentParts?.ledger ?? BudgetLedger(file: appSupport.appendingPathComponent("budget.json"))
        let config = try GooseConfig.openAI(root: appSupport.appendingPathComponent("goose"), model: store.agentModel)
        let agent = BudgetedGooseAgent(config: config, ledger: ledger, launcher: TimedGooseLauncher(inner: PinnedGooseLauncher(executable: gooseExecutable), probe: agentProbe))
        let parts = (agent: agent, broker: broker, ledger: ledger, model: store.agentModel)
        agentParts = parts
        return parts
    }

    private func cancelAgent() {
        agentTask?.cancel()
        agentTask = nil
        if let approval { MainActor.assumeIsolated { approval.dismiss() } } // also cancels the broker turn
        approval = nil
    }

    private var acknowledgmentIndex = Int.random(in: 0..<4)
    private let agentProbe = AgentTimingProbe()

    // MARK: Conversation log (local text, for reviewing mistakes and latency)

    private lazy var conversationLog = ConversationLog(directory: appSupport.appendingPathComponent("conversations"),
                                                       enabled: store.conversationLog)

    private func logEvent(_ event: String, _ fields: [String: Any] = [:]) {
        conversationLog.enabled = store.conversationLog
        conversationLog.record(event, fields)
    }

    private func revealConversations() {
        let directory = conversationLog.directory
        if let latest = ConversationLog.files(in: directory).last {
            NSWorkspace.shared.activateFileViewerSelecting([latest])
        } else {
            store.conversationLogStatus = "Журнал поки порожній."
        }
    }

    private func clearConversations() {
        conversationLog.clear()
        store.conversationLogStatus = "Журнал очищено."
    }

    private static func rounded(_ value: Double?) -> Any {
        value.map { ($0 * 100).rounded() / 100 } ?? NSNull()
    }

    private func runAgent(_ text: String, turn id: Int, language: String) {
        cancelAgent()
        let en = language == "en"
        guard let key = openAIKey(), let parts = try? agentComponents() else {
            finishRequest(turn: id)
            store.stages.action = .failed
            store.actionMessage = en ? "The AI agent is not configured." : "Розумний агент не налаштований."
            return
        }
        beginRequest(turn: id, phase: .agent)
        let voiceTurn = UUID()
        store.stages.action = .active
        store.stages.actionNote = "AI"
        store.actionMessage = en ? "Thinking…" : "Думаю…"
        let context = AgentPlanningContext(broker: parts.broker, turn: voiceTurn, helperExecutable: helperExecutable)
        let started = ProcessInfo.processInfo.systemUptime
        // The first answer takes seconds: Jarvis acknowledges at once, in character.
        let acknowledged = store.spokenReplies
        if acknowledged {
            acknowledgmentIndex += 1
            speak(AgentPersona.acknowledgment(language: language, index: acknowledgmentIndex), language: language)
        }
        let request = AgentPersona.prompt(for: text, language: language, acknowledged: acknowledged)
        wakeTrace("agent start persona v\(AgentPersona.version)")
        logEvent("agent_start", ["request": text, "model": store.agentModel, "persona": AgentPersona.version, "language": language])
        let probe = agentProbe
        agentTask = Task { @MainActor [weak self] in
            await probe.begin()
            do {
                let answer = try await parts.agent.run(text: request, language: language, apiKey: key, planning: context)
                guard let self, !Task.isCancelled, self.store.machine.turn == id else { return }
                let reply = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let seconds = ProcessInfo.processInfo.systemUptime - started
                self.store.stages.action = .done
                self.store.stages.actionNote = answer.cost.map { String(format: "AI %.1f с · $%.4f", seconds, Double($0.micros) / 1_000_000) }
                    ?? String(format: "AI %.1f с", seconds)
                self.store.actionMessage = reply.isEmpty ? (en ? "No text answer." : "Відповіді текстом немає.") : String(reply.prefix(600))
                self.wakeTrace(String(format: "agent ok %.1f s chars=%d", seconds, reply.count))
                let timing = await probe.snapshot()
                self.logEvent("agent", ["reply": reply, "seconds": Self.rounded(seconds), "launch_s": Self.rounded(timing.launch),
                                        "first_text_s": Self.rounded(timing.firstText), "model_rounds": timing.rounds,
                                        "proposals": timing.proposals, "stop": answer.stopReason,
                                        "cost_usd": answer.cost.map { Double($0.micros) / 1_000_000 } ?? NSNull()])
                self.refreshAgentBudget()
                let plans = await parts.broker.pendingPlans()
                guard !Task.isCancelled, self.store.machine.turn == id, self.store.requestActivity.turn == id else { return }
                if plans.isEmpty {
                    self.finishRequest(turn: id)
                } else {
                    self.beginRequest(turn: id, phase: .approval)
                    let controller = AgentApprovalController(broker: parts.broker, turn: voiceTurn, language: language,
                        onEnd: { [weak self] in self?.finishRequest(turn: id) }) { [weak self] _, outcome in
                        self?.agentPlanFinished(outcome, language: language)
                    }
                    self.approval = controller
                    await controller.show()
                }
                guard !Task.isCancelled, self.store.machine.turn == id else { return }
                self.agentTask = nil
                if !reply.isEmpty { self.speakAfterCurrent(AgentPersona.spokenPart(reply), language: language) }
            } catch {
                guard let self, !Task.isCancelled, self.store.machine.turn == id else { return }
                self.agentTask = nil
                self.finishRequest(turn: id)
                self.store.stages.action = .failed
                self.store.stages.actionNote = "AI"
                self.store.actionMessage = Self.agentFailure(error, language: language)
                self.wakeTrace("agent failed \(error)")
                let timing = await probe.snapshot()
                self.logEvent("agent_error", ["error": "\(error)", "seconds": Self.rounded(ProcessInfo.processInfo.systemUptime - started),
                                              "launch_s": Self.rounded(timing.launch), "first_text_s": Self.rounded(timing.firstText)])
                self.refreshAgentBudget()
                self.speakAfterCurrent(en ? "My apologies, sir, the request failed." : "Перепрошую, сер, не вдалося отримати відповідь.", language: language)
            }
        }
    }

    private func agentPlanFinished(_ outcome: CommandOutcome, language: String) {
        logEvent("plan", ["outcome": "\(outcome)"])
        switch outcome {
        case .done(let summary): store.actionMessage = summary; speak(summary, language: language)
        case .partial(let summary, let details): store.actionMessage = summary + " " + details; speak(summary, language: language)
        case .failed(let reason): store.actionMessage = reason; speak(reason, language: language)
        default: break
        }
    }

    static func agentFailure(_ error: Error, language: String) -> String {
        let en = language == "en"
        switch error {
        case BudgetError.exhausted: return en ? "The monthly AI budget ($10) is used up." : "Місячний бюджет AI ($10) вичерпано."
        case AgentError.busy: return en ? "The previous AI request is still finishing." : "Попередній запит AI ще завершується."
        case AgentError.timeout: return en ? "The AI did not answer in time." : "AI не відповів вчасно."
        case AgentError.invalidConfiguration: return en ? "AI setup is invalid: check the bundled runtime and model name." : "Налаштування AI некоректні: перевірте модель і вбудований Goose."
        case AgentError.provider(let code): return en ? "The AI returned an error (\(code)). Check the OpenAI key, model and balance." : "AI повернув помилку (\(code)). Перевірте ключ OpenAI, модель і баланс."
        default: return en ? "The AI request failed." : "Не вдалося отримати відповідь AI."
        }
    }

    private func refreshAgentBudget() {
        guard let ledger = agentParts?.ledger else { return }
        Task { @MainActor [weak self] in
            guard let snapshot = try? await ledger.snapshot() else { return }
            self?.store.agentBudget = String(format: "Цього місяця: $%.2f з $%.0f", Double(snapshot.committed.micros) / 1_000_000, Double(snapshot.limit.micros) / 1_000_000)
        }
    }

    private func saveOpenAIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if KeychainSecret.save(trimmed, KeychainSecret.openAI) {
            cachedOpenAIKey = trimmed
            store.hasOpenAIKey = true
            store.agentStatus = "Ключ OpenAI збережено в Keychain."
        } else {
            store.agentStatus = "Не вдалося зберегти ключ у Keychain."
        }
    }

    private func deleteOpenAIKey() {
        KeychainSecret.delete(KeychainSecret.openAI)
        cachedOpenAIKey = nil
        store.hasOpenAIKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil
        store.agentStatus = "Ключ OpenAI видалено з Keychain."
    }

    private func present(_ outcome: CommandOutcome, turn id: Int, language: String, seconds: Double) {
        let en = language == "en"
        let spoken: String
        switch outcome {
        case .done(let summary):
            store.stages.action = .done
            store.stages.actionNote = String(format: "%.2f с", seconds)
            store.actionMessage = summary
            spoken = summary
        case .partial(let summary, let details):
            store.stages.action = .failed
            store.stages.actionNote = en ? "partly" : "частково"
            store.actionMessage = summary + " " + details
            spoken = summary + " " + details
        case .failed(let reason):
            store.stages.action = .failed
            store.stages.actionNote = en ? "failed" : "не виконано"
            store.actionMessage = reason
            spoken = reason
        case .needsApproval:
            // No action in the current registry asks for approval; never auto-approve.
            store.stages.action = .failed
            store.stages.actionNote = en ? "needs approval" : "потрібне підтвердження"
            store.actionMessage = en ? "This action needs confirmation, which is not connected yet." : "Ця дія потребує підтвердження, яке ще не підключено."
            spoken = store.actionMessage
        case .notUnderstood where agentAvailable:
            logEvent("action", ["result": "notUnderstood", "next": "agent", "seconds": Self.rounded(seconds)])
            runAgent(lastCommandText, turn: lastCommandTurn, language: language)
            return
        case .notUnderstood:
            store.stages.action = .failed
            store.stages.actionNote = en ? "not understood" : "не зрозумів"
            store.actionMessage = en ? "I don't know this command yet. Try “open Safari” or “volume up”."
                                     : "Поки не знаю такої команди. Спробуйте «відкрий Safari» або «зроби гучніше»."
            spoken = en ? "I don't know this command yet." : "Поки не знаю такої команди."
        }
        wakeTrace(String(format: "action %@ %.2f s", "\(outcome)".prefix(12).description, seconds))
        logEvent("action", ["result": "\(outcome)", "message": store.actionMessage, "seconds": Self.rounded(seconds)])
        finishRequest(turn: id)
        speak(spoken, language: language)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping (JarvisApp) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            if let self { handler(self) }
        }
        observers.append((center, token))
    }

    // MARK: Surfaces

    private func makeMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Сховати Jarvis", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Завершити Jarvis", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Редагування")
        editMenu.addItem(withTitle: "Копіювати", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Виділити все", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Вікно")
        windowMenu.addItem(withTitle: "Закрити", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Згорнути", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    private func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Jarvis"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.020, green: 0.039, blue: 0.063, alpha: 1)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1000, height: 680)
        window.contentView = FirstMouseHostingView(rootView: MainView(store: store, level: level, actions: actions))
        window.center()
        window.setFrameAutosaveName("JarvisMain")
        window.makeKeyAndOrderFront(nil)
    }

    private func makeHUD() {
        hud = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 64),
                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        hud.isFloatingPanel = true
        hud.level = .statusBar
        hud.hidesOnDeactivate = false
        hud.becomesKeyOnlyIfNeeded = true
        hud.isOpaque = false
        hud.backgroundColor = .clear
        hud.hasShadow = true
        hud.isMovableByWindowBackground = true
        hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hud.title = "Jarvis HUD"
        hud.contentView = FirstMouseHostingView(rootView: HUDView(store: store, level: level, actions: actions))
    }

    private func showHUD() {
        hudHide?.invalidate()
        hudHide = nil
        guard !hud.isVisible else { return }
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            hud.setFrameOrigin(NSPoint(x: f.midX - 260, y: f.minY + 36))
        }
        store.hudVisible = true
        hud.orderFrontRegardless() // never makeKey: the target field keeps focus
    }

    private func hideHUD(after seconds: Double) {
        hudHide?.invalidate()
        guard hud.isVisible else { return }
        hudHide = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self, !self.store.canCancel else { return }
            self.hud.orderOut(nil)
            self.store.hudVisible = false
            self.hudHide = nil
        }
    }

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        let symbol: String
        switch store.phase {
        case .microphoneOff: symbol = "mic.slash"
        case .wakeListening: symbol = "ear"
        case .recording: symbol = "waveform.circle.fill"
        case .transcribing: symbol = "ellipsis.circle"
        case .error, .modelUnavailable: symbol = "exclamationmark.triangle"
        default: symbol = "waveform"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Jarvis: \(store.headline)")
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = "Jarvis — \(store.headline)"
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

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    @objc private func toggleMicrophoneFromMenu() { toggleMicrophone() }
    @objc private func toggleWakeFromMenu() { toggleWake() }
    @objc private func cancelFromMenu() { cancelSession(message: "Скасовано. Запис зупинено, результат відкинуто.") }
    @objc private func quit() { NSApp.terminate(nil) }

    private func stateChanged(_ machine: VoiceMachine) {
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

    // MARK: Model

    private func setModel(_ index: Int) {
        guard !store.machine.busy, index != store.modelIndex, store.modelTitles.indices.contains(index) else { return }
        store.modelIndex = index
        loadSelectedModel()
    }

    private func setLanguage(_ index: Int) {
        guard !store.machine.busy, store.languageTitles.indices.contains(index) else { return }
        screening.invalidate()
        store.languageIndex = index
        refreshMeasurement()
    }

    private func loadSelectedModel() {
        screening.invalidate()
        store.machine.modelLoading()
        store.recordLimit = recordingLimit
        refreshMeasurement()
        let path = modelName == "parakeet-uk-v3"
            ? projectRoot + "/.runtime/parakeet-probe/model/parakeet-tdt-0.6b-v3"
            : projectRoot + "/.runtime/models/ggml-" + modelName + ".bin"
        speech.load(path: path) { [weak self] ready in
            self?.store.machine.modelLoaded(ready)
            guard ready else { return }
            self?.speech.warmUp { seconds in self?.wakeTrace(String(format: "asr warm-up %.2f s", seconds)) }
        }
    }

    // MARK: Hotkeys

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
            if (identifier.id == 2 || identifier.id == 3) && pressed {
                if app.store.machine.speaking && !app.store.requestActivity.active { app.stopSpeaking() } else { app.cancelSession(message: "Скасовано. Запис зупинено, результат відкинуто.") }
            }
            return noErr
        }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard handlerStatus == noErr else { store.hotKeyAvailable = false; return }
        store.hotKeyAvailable = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey),
            EventHotKeyID(signature: hotKeySignature, id: 1), GetApplicationEventTarget(), 0, &hotKey) == noErr
    }

    private func enableEscape() {
        guard escapeKey == nil else { return }
        let result = RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: hotKeySignature, id: 2),
                            GetApplicationEventTarget(), 0, &escapeKey)
        let chordResult = RegisterEventHotKey(UInt32(kVK_Escape), UInt32(controlKey | optionKey),
            EventHotKeyID(signature: hotKeySignature, id: 3), GetApplicationEventTarget(), 0, &escapeChord)
        store.escapeUnavailable = result != noErr && chordResult != noErr
    }

    private func disableEscape() {
        guard !store.canCancel else { enableEscape(); return }
        if let escapeKey { UnregisterEventHotKey(escapeKey) }
        escapeKey = nil
        if let escapeChord { UnregisterEventHotKey(escapeChord) }
        escapeChord = nil
    }

    // MARK: Microphone

    private func toggleMicrophone() {
        if store.machine.microphoneEnabled {
            cancelSession(message: "")
            // Full mic-off: wake monitoring stops too and the engine closes.
            wake.stop()
            audio.shutdown()
            resumeWakeOnWake = false
            store.machine.setMicrophone(enabled: false)
            return
        }
        guard !store.permissionPending else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            store.permissionDenied = false
            store.machine.setMicrophone(enabled: true)
        case .notDetermined:
            store.permissionPending = true
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.store.permissionPending = false
                    self.store.permissionDenied = !granted
                    self.store.machine.setMicrophone(enabled: granted)
                    // Deliberately never call keyDown here, even if the key is held.
                    if granted && self.store.pendingWake { self.continueEnablingWake() }
                    if !granted { self.store.pendingWake = false }
                }
            }
        default:
            store.permissionDenied = true
            store.pendingWake = false
            store.machine.setMicrophone(enabled: false)
        }
    }

    private func keyDown() {
        stopSpeaking() // PTT interrupts a spoken reply
        let authorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        guard gate.press(enabled: store.machine.microphoneEnabled, authorized: authorized,
                         ready: store.machine.canRecord && store.hotKeyAvailable) else { return }
        wake.setMode(.off) // PTT takes over; the detector must not fire mid-command
        guard let id = store.machine.beginRecording() else { gate.cancel(); return }
        do { try audio.start(maximumSeconds: recordingLimit) } catch {
            cancelSession(message: "")
            store.machine.fail(message: error.localizedDescription)
            return
        }
        source = .ptt
        store.keyRecording = true
        beginTurnUI(id)
    }

    /// Shared by PTT and wake-started turns once audio is being recorded.
    private func beginTurnUI(_ id: Int) {
        cancelCommand()
        store.actionMessage = ""
        captureFocus()
        screening.invalidate() // old screening results cannot create another turn
        turn = id
        started = ProcessInfo.processInfo.systemUptime
        store.recordElapsed = 0
        store.stages = TurnStages(record: .active)
        let capture = audio
        meter.start { capture.meterSnapshot() }
        enableEscape()
        clock = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.store.recordElapsed = ProcessInfo.processInfo.systemUptime - self.started
        }
        timeout = Timer.scheduledTimer(withTimeInterval: Double(recordingLimit), repeats: false) { [weak self] _ in
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
        guard clock != nil, let id = turn else { return }
        let releasedAt = ProcessInfo.processInfo.systemUptime
        gate.cancel()
        stopTimers()
        meter.stop()
        wake.setMode(.off)
        let recorded = audio.stop()
        // Wake commands end on silence; drop most of it so ASR does not invent
        // words. PTT audio is kept exactly as recorded (measurement baseline).
        let samples = source == .wake ? SpeechEndpoint.trimTrailingSilence(recorded) : recorded
        let duration = Double(samples.count) / 16_000
        if source == .wake { wakeTrace(String(format: "command recorded %.2f s, after trim %.2f s", Double(recorded.count) / 16_000, duration)) }
        let wasDiagnostic = diagnostic.armed
        if wasDiagnostic {
            store.diagnosticArmed = false
            if duration < 0.25 || timedOut {
                diagnostic.cancel()
                store.diagnosticLabel = "Діагностичний запис скасовано: надто короткий або досягнуто ліміту."
            } else {
                do {
                    store.diagnosticURL = try diagnostic.finish(samples: samples,
                        directory: URL(fileURLWithPath: projectRoot + "/.runtime/diagnostics"))
                    store.diagnosticLabel = "WAV збережено локально. Збереження наступних фраз вимкнено."
                } catch {
                    store.diagnosticLabel = "Не вдалося зберегти WAV: " + error.localizedDescription
                }
            }
        }
        guard duration >= 0.25 else {
            disableEscape()
            turn = nil
            store.stages = TurnStages()
            store.machine.abandon(turn: id, message: source == .wake
                ? "Не почув команди після «Jarvis». Скажіть ще раз."
                : "Запис надто короткий. Утримуйте ⌃⌥Пробіл і скажіть фразу.")
            return
        }
        store.machine.beginTranscribing(turn: id, timedOut: timedOut)
        store.stages.record = .done
        store.stages.audioSeconds = duration
        store.stages.recognize = .active
        let code = languageCode
        let measured = store.measuring && !wasDiagnostic ? currentPrompt() : nil
        let measuredModel = modelName
        let fromWake = source == .wake
        let prefixConfirmed = wakePrefixConfirmed
        speech.transcribe(samples, language: code) { [weak self] raw, elapsed in
            guard let self, self.turn == id, self.store.machine.phase == .transcribing else { return }
            var text = raw
            if fromWake, let heard = raw {
                guard let command = WakeText.command(from: heard, prefixConfirmed: prefixConfirmed) else {
                    // A KWS hint is not permission to execute a background mention.
                    self.turn = nil
                    self.store.stages = TurnStages()
                    self.store.machine.abandon(turn: id, message: "")
                    self.disableEscape()
                    return
                }
                text = command
                self.wakeTrace(String(format: "asr done %.2f s, chars=%d, prefixConfirmed=%@, command chars=%d",
                                      elapsed, heard.count, prefixConfirmed ? "yes" : "no", command.count))
                if command.isEmpty {
                    self.turn = nil
                    self.store.stages = TurnStages()
                    self.store.machine.abandon(turn: id, message: "Не почув команди після «Jarvis». Скажіть ще раз.")
                    self.disableEscape()
                    return
                }
            }
            // Stale results of cancelled turns are dropped by both LocalSpeech
            // generations and the turn id.
            // Shown and passed on in clean Ukrainian; measurements keep the raw ASR text.
            let shown = text.map { TranscriptCleanup.normalize($0, language: code) }
            guard self.store.machine.finishTranscription(turn: id, text: shown) else { return }
            if measured == nil, !wasDiagnostic {
                self.conversationLog.beginTurn(id, at: releasedAt)
                self.logEvent("heard", ["source": fromWake ? "wake" : "ptt", "language": code, "raw": raw ?? NSNull(),
                                        "shown": shown ?? NSNull(), "audio_s": Self.rounded(duration), "asr_s": Self.rounded(elapsed)])
            }
            let responseTime = ProcessInfo.processInfo.systemUptime - releasedAt
            self.turn = nil
            self.disableEscape()
            self.store.stages.asrSeconds = elapsed
            self.store.stages.responseSeconds = responseTime
            self.store.stages.recognize = text == nil ? .failed : .done
            self.store.stages.text = (text?.isEmpty ?? true) ? .failed : .done
            // Measurement prompts and diagnostic recordings are never executed.
            if measured == nil, !wasDiagnostic, let shown, !shown.isEmpty { self.runCommand(shown, turn: id, language: code) }
            if let measured {
                let status: MeasurementRecord.Status = text == nil ? .error : (text!.isEmpty ? .empty : .ok)
                self.logMeasurement(measured, model: measuredModel, languageSetting: code, transcript: text ?? "",
                                    status: status, timedOut: timedOut, audio: duration, whisper: elapsed, response: responseTime)
            }
        }
    }

    private func stopTimers() {
        clock?.invalidate()
        timeout?.invalidate()
        clock = nil
        timeout = nil
    }

    private func cancelSession(message: String) {
        wakeActivationRequest = nil
        store.wakeLoading = false
        store.pendingWake = false
        screening.invalidate()
        cancelCommand()
        MainActor.assumeIsolated { executor.invalidateDictationTarget() }
        dictationToken = nil
        voice.stop()
        speechToken += 1
        gate.cancel()
        if diagnostic.armed {
            diagnostic.cancel()
            store.diagnosticArmed = false
            store.diagnosticLabel = "Збереження скасовано. Новий файл не створено."
        }
        stopTimers()
        wake.setMode(.off)
        audio.stop() // keeps wake monitoring running if it is enabled
        meter.stop()
        if store.machine.model != .loading { speech.cancel() }
        disableEscape()
        turn = nil
        if store.stages.record == .active || store.stages.recognize == .active { store.stages = TurnStages() }
        store.machine.cancel(message: message)
        refreshEscape()
    }

    // MARK: Spoken replies

    private let voice = SpeechOutput()
    private var speechToken = 0

    /// Speaks a short reply with the chosen voice. Wake detection is paused
    /// for the whole reply and a short tail, so Jarvis never hears itself.
    func speak(_ text: String, language: String) {
        queuedSpeech = nil
        guard store.spokenReplies, !store.machine.busy else { return }
        let voiceID = language == "en" ? store.voiceEN : store.voiceUK
        guard store.machine.beginSpeaking() else { return }
        logEvent("speak", ["text": text, "language": language])
        speechToken += 1
        enableEscape()
        showHUD()
        if !voice.speak(text, language: language, localVoiceID: voiceID, cloud: cloudPlan()) {
            store.machine.finishSpeaking()
            disableEscape()
        }
    }

    func stopSpeaking() {
        queuedSpeech = nil
        guard store.machine.speaking else { return }
        speechToken += 1
        voice.stop()
        store.machine.finishSpeaking()
        disableEscape()
    }

    /// A reply that arrived while the acknowledgment was still playing.
    private var queuedSpeech: (text: String, language: String)?

    /// Lets "Хвилинку, сер" finish before the answer starts.
    func speakAfterCurrent(_ text: String, language: String) {
        if store.machine.speaking && voice.isSpeaking { queuedSpeech = (text, language) } else { speak(text, language: language) }
    }

    private func speechEnded() {
        if let next = queuedSpeech {
            queuedSpeech = nil
            speechToken += 1
            let voiceID = next.language == "en" ? store.voiceEN : store.voiceUK
            if store.machine.speaking { logEvent("speak", ["text": next.text, "language": next.language, "after_acknowledgment": true]) }
            if store.machine.speaking, voice.speak(next.text, language: next.language, localVoiceID: voiceID, cloud: cloudPlan()) { return }
        }
        speechToken += 1
        let token = speechToken
        // Room echo of the last syllable must not reach the detector.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, token == self.speechToken, self.store.machine.speaking else { return }
            self.store.machine.finishSpeaking()
            self.disableEscape()
        }
    }

    private var cachedCloudKey: String?

    /// ElevenLabs only when the user enabled it and a key exists (environment
    /// variable or Keychain). The key is read once and kept in memory.
    private func cloudPlan() -> SpeechOutput.CloudPlan? {
        guard store.cloudVoiceEnabled else {
            store.cloudStatus = "ElevenLabs вимкнено перемикачем — відповідає голос macOS."
            return nil
        }
        if cachedCloudKey == nil {
            cachedCloudKey = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"] ?? KeychainSecret.read(KeychainSecret.elevenLabs)
        }
        guard let key = cachedCloudKey, !key.isEmpty else {
            store.cloudStatus = "Немає ключа ElevenLabs — відповідає голос macOS."
            return nil
        }
        return SpeechOutput.CloudPlan(voiceID: store.elevenVoiceID, apiKey: key, monthlyCharacterLimit: store.cloudCharacterLimit)
    }

    private func cloudResult(_ reason: String?, characters: Int, seconds: Double) {
        store.refreshCloudUsage()
        store.cloudStatus = reason.map { "Відповів голос macOS: \($0)." }
            ?? String(format: "Відповів ElevenLabs, звук отримано за %.2f с.", seconds)
        wakeTrace(String(format: "cloud tts %@ chars=%d %.2f s", reason == nil ? "ok" : "fallback", characters, seconds))
        logEvent("voice", ["engine": reason != nil ? "macos" : (characters == 0 ? "elevenlabs-cached" : "elevenlabs"),
                           "request_s": Self.rounded(seconds), "fallback_reason": reason ?? NSNull()])
    }

    private func saveCloudKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if KeychainSecret.save(trimmed, KeychainSecret.elevenLabs) {
            cachedCloudKey = trimmed
            voice.resetCloudPause()
            store.hasCloudKey = true
            store.cloudVoiceEnabled = true // saving a key means "use ElevenLabs"
            store.cloudStatus = "Ключ збережено в Keychain."
        } else {
            store.cloudStatus = "Не вдалося зберегти ключ у Keychain."
        }
    }

    private func deleteCloudKey() {
        KeychainSecret.delete(KeychainSecret.elevenLabs)
        cachedCloudKey = nil
        store.hasCloudKey = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"] != nil
        store.cloudStatus = "Ключ видалено з Keychain."
    }

    private func previewVoice(_ language: String) {
        if store.machine.speaking { stopSpeaking() }
        let wasEnabled = store.spokenReplies
        store.spokenReplies = true // preview works even in text-only mode
        speak(SpeechOutput.sample(for: language), language: language)
        store.spokenReplies = wasEnabled
    }

    // MARK: Voice activation

    private var wakeModelDir: String { projectRoot + "/.runtime/kws/en-2023-06-26" }

    private func toggleWake() {
        if store.machine.wakeEnabled {
            disableWake(message: "")
            return
        }
        guard !store.wakeLoading else { return }
        guard store.machine.microphoneEnabled else {
            // One explicit action: enable the mic (asking permission if needed), then activation.
            store.pendingWake = true
            toggleMicrophone()
            if store.machine.microphoneEnabled { continueEnablingWake() }
            return
        }
        continueEnablingWake()
    }

    /// Called after the microphone is enabled for a pending activation request.
    private func continueEnablingWake() {
        screening.invalidate()
        store.pendingWake = false
        guard store.machine.microphoneEnabled, !store.machine.wakeEnabled else { return }
        let request = UUID()
        wakeActivationRequest = request
        store.wakeLoading = true
        wake.load(modelDir: wakeModelDir) { [weak self] ok in
            guard let self, self.wakeActivationRequest == request else { return }
            self.wakeActivationRequest = nil
            self.store.wakeLoading = false
            guard ok else {
                self.store.wakeError = "Модель активації не знайдена. Запустіть scripts/setup-wake.sh."
                return
            }
            guard self.store.machine.microphoneEnabled else { return }
            do {
                try self.audio.startMonitoring()
            } catch {
                self.store.wakeError = "Не вдалося увімкнути мікрофон для активації: " + error.localizedDescription
                return
            }
            self.store.wakeError = ""
            self.wake.start(capture: self.audio)
            self.store.machine.setWake(enabled: true)
        }
    }

    private func disableWake(message: String) {
        wakeActivationRequest = nil
        store.wakeLoading = false
        store.pendingWake = false
        screening.invalidate()
        if source == .wake && store.machine.busy { cancelSession(message: "") }
        wake.stop()
        audio.stopMonitoring()
        resumeWakeOnWake = false
        store.machine.setWake(enabled: false)
        store.wakeError = message
    }

    private func wakeEvent(_ event: WakeListener.Event) {
        switch event {
        case .utterance(let samples, let end, let epoch):
            let segment = Segment(samples: samples, end: end, epoch: epoch, heardAt: ProcessInfo.processInfo.systemUptime)
            screen(segment)
        case .wake(let generation, let prefixConfirmed):
            // The listener already started the command recording atomically.
            // Accept it only if this is still an idle, armed state.
            wakeTrace("wake gen=\(generation) armed=\(store.machine.wakeArmed) phase=\(store.machine.phase) recGen=\(String(describing: audio.recordingGeneration))")
            // A queued event from an older capture must not stop a newer one.
            guard audio.recordingGeneration == generation else { return }
            guard store.machine.wakeArmed, let id = store.machine.beginRecording() else {
                wakeTrace("wake rejected")
                if audio.recordingGeneration == generation { audio.stop() }
                wake.setMode(.off)
                if store.machine.wakeArmed { wake.setMode(.armed) }
                return
            }
            wakePrefixConfirmed = prefixConfirmed
            source = .wake
            store.keyRecording = false
            beginTurnUI(id)
            acknowledge()
        case .endpoint(let outcome, let generation):
            wakeTrace("endpoint \(outcome) source=\(source) phase=\(store.machine.phase)")
            guard source == .wake, store.machine.phase == .recording, turn != nil,
                  audio.recordingGeneration == generation else { return }
            switch outcome {
            case .speechEnded:
                finishRecording(timedOut: false)
            case .noSpeech:
                // The recording starts before the keyword, so a short command
                // said in one breath ("Джарвіс, стоп") may already be in it.
                // Transcribe; an empty command after stripping is abandoned.
                finishRecording(timedOut: false)
            case .listening:
                break
            }
        }
    }

    private var canScreen: Bool {
        modelName == "parakeet-uk-v3" && store.machine.wakeArmed && !store.machine.busy
    }

    private func screen(_ segment: Segment) {
        guard canScreen, let job = screening.submit(segment) else { return }
        speech.screen(job.element.samples, language: languageCode) { [weak self] heard, elapsed in
            guard let self else { return }
            defer {
                if let next = self.screening.finish(job.ticket) { self.screen(next) }
            }
            guard self.screening.isCurrent(job.ticket), self.canScreen, let heard else { return }
            let stripped = WakeText.stripLeadingWakeWord(heard)
            self.wakeTrace(String(format: "screen %.2f s audio, asr %.2f s, keyword=%@, command chars=%d",
                                  Double(segment.samples.count) / 16_000, elapsed,
                                  stripped.found ? "yes" : "no", stripped.found ? stripped.text.count : -1))
            guard stripped.found else { return }
            if stripped.text.isEmpty {
                self.wake.startCommand(after: segment.end, epoch: segment.epoch)
                return
            }
            self.presentScreenedCommand(stripped.text, segment: segment, asrSeconds: elapsed)
        }
    }

    /// The whole «Джарвіс, <команда>» phrase was already heard and recognised.
    private func presentScreenedCommand(_ text: String, segment: Segment, asrSeconds: Double) {
        guard let id = store.machine.beginRecording() else { return }
        cancelCommand()
        store.actionMessage = ""
        captureFocus()
        source = .wake
        screening.invalidate()
        store.stages = TurnStages(record: .done, recognize: .done, text: .done,
                                  audioSeconds: Double(segment.samples.count) / 16_000,
                                  asrSeconds: asrSeconds,
                                  responseSeconds: ProcessInfo.processInfo.systemUptime - segment.heardAt)
        store.machine.beginTranscribing(turn: id, timedOut: false)
        let command = TranscriptCleanup.normalize(text, language: languageCode)
        _ = store.machine.finishTranscription(turn: id, text: command)
        conversationLog.beginTurn(id, at: segment.heardAt)
        logEvent("heard", ["source": "wake-phrase", "language": languageCode, "raw": text, "shown": command,
                           "audio_s": Self.rounded(Double(segment.samples.count) / 16_000), "asr_s": Self.rounded(asrSeconds)])
        acknowledge()
        runCommand(command, turn: id, language: languageCode)
    }

    private func acknowledge() {
        guard store.acknowledgmentSound else { return }
        chime.play()
    }

    private func restartMonitoring(reason: Error) {
        screening.invalidate()
        wake.setMode(.off)
        audio.stopMonitoring()
        do {
            try audio.startMonitoring()
            wake.start(capture: audio)
            if store.machine.wakeArmed { wake.setMode(.armed) }
        } catch {
            disableWake(message: "Активацію вимкнено: \(reason.localizedDescription)")
        }
    }

    /// Sleep / session switch: stop every capture, remember wake monitoring.
    private func suspendCapture(message: String) {
        cancelSession(message: message)
        if store.machine.wakeEnabled && audio.isMonitoring {
            resumeWakeOnWake = true
            wake.stop()
            audio.stopMonitoring()
        }
    }

    private func resumeCapture() {
        guard resumeWakeOnWake else { return }
        resumeWakeOnWake = false
        guard store.machine.wakeEnabled, store.machine.microphoneEnabled else { return }
        do {
            try audio.startMonitoring()
            wake.start(capture: audio)
            if store.machine.wakeArmed { wake.setMode(.armed) }
        } catch {
            disableWake(message: "Не вдалося відновити активацію після сну: " + error.localizedDescription)
        }
    }

    // MARK: Diagnostics

    private func toggleDiagnostic() {
        guard !store.machine.busy else { return }
        if diagnostic.armed {
            diagnostic.cancel()
            store.diagnosticArmed = false
            store.diagnosticLabel = "Збереження аудіо вимкнено."
        } else {
            diagnostic.arm()
            store.diagnosticArmed = true
            store.diagnosticLabel = "Наступну фразу буде збережено локально (16 кГц WAV). Скажіть 5–8 секунд; Esc скасовує."
        }
    }

    private func revealDiagnostic() {
        if let url = store.diagnosticURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    private func copyTranscript() {
        guard !store.machine.transcript.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.machine.transcript, forType: .string)
    }

    // MARK: Measurement mode

    private func setMeasuring(_ on: Bool) {
        guard !store.machine.busy else { return }
        store.measuring = on
        refreshMeasurement()
    }

    private func currentPrompt() -> (progress: MeasurementProgress, prompt: Prompt)? {
        guard let progress, !progress.finished, progress.index < prompts.count else { return nil }
        return (progress, prompts[progress.index])
    }

    private func refreshMeasurement() {
        guard store.measuring else {
            store.canSkipPrompt = false
            return
        }
        if prompts.isEmpty {
            let path = projectRoot + "/docs/benchmarks/prompts.txt"
            prompts = PromptSet.parse((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
            measurementLog = MeasurementLog(url: URL(fileURLWithPath: projectRoot + "/.runtime/measurements/uk-en-v1.jsonl"))
        }
        guard !prompts.isEmpty, let measurementLog else {
            store.measurementPrompt = "Не знайдено docs/benchmarks/prompts.txt."
            store.canSkipPrompt = false
            return
        }
        progress = MeasurementProgress.next(records: measurementLog.records(), model: modelName,
                                            languageSetting: languageCode, promptCount: prompts.count)
        if let current = currentPrompt() {
            store.measurementPrompt = "Прохід \(current.progress.pass)/\(MeasurementProgress.passes) · \(current.progress.index + 1)/\(prompts.count) · [\(current.prompt.language)] \(current.prompt.text)"
            store.canSkipPrompt = true
        } else {
            store.measurementPrompt = "Усі \(MeasurementProgress.passes) проходи для \(modelName) / \(languageCode) записано. Запустіть scripts/analyze_measurements.py."
            store.canSkipPrompt = false
        }
    }

    private func skipPrompt() {
        guard !store.machine.busy, let current = currentPrompt() else { return }
        logMeasurement(current, model: modelName, languageSetting: languageCode, transcript: "",
                       status: .skipped, timedOut: false, audio: 0, whisper: 0, response: 0)
    }

    private func logMeasurement(_ current: (progress: MeasurementProgress, prompt: Prompt), model: String, languageSetting: String,
                                transcript: String, status: MeasurementRecord.Status, timedOut: Bool,
                                audio: Double, whisper: Double, response: Double) {
        let record = MeasurementRecord(
            timestamp: ISO8601DateFormatter().string(from: Date()), model: model, languageSetting: languageSetting,
            pass: current.progress.pass, promptIndex: current.progress.index, promptLanguage: current.prompt.language,
            expected: current.prompt.text, transcript: transcript, status: status, timedOut: timedOut,
            audioSeconds: audio, whisperSeconds: whisper, responseSeconds: response)
        do { try measurementLog?.append(record) } catch {
            store.measurementPrompt = "Не вдалося записати вимір: \(error.localizedDescription)"
            return
        }
        refreshMeasurement()
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
