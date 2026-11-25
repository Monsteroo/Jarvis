import Foundation

actor ActionEvents {
    private var listeners: [UUID: AsyncStream<ActionEvent>.Continuation] = [:]
    func subscribe() -> AsyncStream<ActionEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            listeners[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.remove(id) } }
        }
    }
    private func remove(_ id: UUID) { listeners.removeValue(forKey: id) }
    func emit(_ event: ActionEvent) { for listener in listeners.values { listener.yield(event) } }
}

final class ActionExecutor: CommandHandling {
    private let workspace: ActionWorkspace
    private let windows: WindowActions?
    private let uiElements: UIElementActions?
    private let shortcuts: ShortcutActions?
    private let appleShortcuts: AppleShortcutActions?
    private let audioOutput: AudioOutputActions?
    private let dictation: DictationActions?
    private let history: HistoryStore?
    private let parser = IntentParser()
    private let registry = ActionRegistry()
    let events = ActionEvents()

    init(workspace: ActionWorkspace, windows: WindowActions? = nil, uiElements: UIElementActions? = nil, audioOutput: AudioOutputActions? = nil, dictation: DictationActions? = nil, history: HistoryStore? = nil, shortcuts: ShortcutActions? = nil, appleShortcuts: AppleShortcutActions? = nil) {
        self.workspace = workspace; self.windows = windows; self.uiElements = uiElements; self.shortcuts = shortcuts
        self.appleShortcuts = appleShortcuts; self.audioOutput = audioOutput; self.dictation = dictation; self.history = history
    }
    @MainActor static func live(aliases: AppAliases = .defaults, history: HistoryStore? = nil) -> ActionExecutor {
        ActionExecutor(workspace: MacActionWorkspace(aliases: aliases), windows: WindowActions(access: MacWindowAccess()), uiElements: UIElementActions(access: MacUIElementAccess()), audioOutput: AudioOutputActions(access: MacOutputAccess()), dictation: DictationActions(access: MacDictationAccess()), history: history, shortcuts: ShortcutActions(access: MacShortcutAccess()), appleShortcuts: AppleShortcutActions.live())
    }

    var appleShortcutBridge: AppleShortcutActions? { appleShortcuts }
    func allowlistedShortcutNames() -> [String] { appleShortcuts?.allowlistedNames() ?? [] }

    @MainActor func captureDictationTarget() throws -> UUID {
        guard let dictation else { throw DeviceActionError.unavailable }
        return try dictation.capture()
    }
    @MainActor func invalidateDictationTarget() { dictation?.invalidate() }
    @MainActor func clearUISnapshots() { uiElements?.clearSnapshots() }
    /// Reads a window after the owner allowed it on screen (any app except the blocked ones).
    @MainActor func uiSnapshotWithOwnerConsent(_ action: Action, language: String) async -> CommandOutcome {
        guard case .uiSnapshot = action, (try? registry.validate(action)) != nil else {
            return .failed(reason: actionText(language, "Некоректні параметри команди.", "Invalid command parameters."))
        }
        guard let uiElements else {
            return .failed(reason: actionText(language, "Керування елементами вікна не підключено.", "Window element control is not connected."))
        }
        return await uiElements.perform(action, language: language, ownerConsented: true)
    }
    @MainActor func describeUIAction(_ action: Action) -> String? { uiElements?.describeTarget(for: action) }
    @MainActor func effectivePolicy(for action: Action) -> ApprovalPolicy {
        if let shortcutPolicy = appleShortcuts?.effectivePolicy(for: action) { return shortcutPolicy }
        return uiElements?.effectivePolicy(for: action) ?? registry.policy(for: action)
    }

    func handle(_ text: String, language: String) async -> CommandOutcome {
        await handle(text, language: language, dictationToken: nil)
    }
    func handle(_ text: String, language: String, dictationToken: UUID?) async -> CommandOutcome {
        guard language == "uk" || language == "en" else {
            return .failed(reason: "Оберіть українську або англійську мову.")
        }
        guard !Task.isCancelled else { return cancelled(language) }
        let parsed = parser.parse(text, language: language)
            ?? appleShortcuts?.matchDirectPhrase(text, language: language).map { Action.runShortcut($0.name) }
        guard let action = parsed else { return .notUnderstood }
        if case .runShortcut(let rawName) = action,
           let entry = appleShortcuts?.resolve(rawName, language: language),
           entry.requiresConfirmation {
            let summary = actionText(language, "Запустити команду Apple Shortcuts «\(entry.name)»?", "Run Apple Shortcut ‘\(entry.name)’?")
            return .needsApproval(ApprovalRequest(id: UUID(), turnID: UUID(), action: .runShortcut(entry.name), summary: summary, expiresAt: Date().addingTimeInterval(120)))
        }
        return await handle(action: action, language: language, dictationToken: dictationToken)
    }
    /// Typed callers still pass through the same language/schema/cancellation gates.
    func handle(action: Action, language: String, dictationToken: UUID? = nil) async -> CommandOutcome {
        guard language == "uk" || language == "en" else { return .failed(reason: "Оберіть українську або англійську мову.") }
        guard !Task.isCancelled else { return cancelled(language) }
        do { try registry.validate(action) }
        catch { return .failed(reason: actionText(language, "Некоректні параметри команди.", "Invalid command parameters.")) }
        let turnID = UUID()
        await events.emit(ActionEvent(turnID: turnID, action: action, phase: .started))
        let started = ProcessInfo.processInfo.systemUptime
        var result: CommandOutcome
        do {
            try Task.checkCancellation()
            result = try await execute(action, language: language, dictationToken: dictationToken)
        } catch is CancellationError { result = cancelled(language) }
        catch { result = .failed(reason: actionText(language, "Не вдалося виконати дію. Перевірте програму й повторіть спробу.", "The action failed. Check the application and try again.")) }
        // A window snapshot is read-only and its summary is the window text for the
        // model only: a history failure must not turn it into a "partial" that is spoken.
        let isSnapshot: Bool = { if case .uiSnapshot = action { return true }; return false }()
        if let history, !isSnapshot {
            do { try await history.record(action: action, outcome: result, duration: ProcessInfo.processInfo.systemUptime - started) }
            catch {
                let warning = actionText(language, "Не вдалося зберегти історію.", "History could not be saved.")
                switch result {
                case .done(let summary): result = .partial(summary: summary, details: warning)
                case .partial(let summary, let details): result = .partial(summary: summary, details: details + " " + warning)
                case .failed(let reason): result = .failed(reason: reason + " " + warning)
                default: break
                }
            }
        }
        await events.emit(ActionEvent(turnID: turnID, action: action, phase: .finished(result)))
        return result
    }

    private func cancelled(_ language: String) -> CommandOutcome {
        .failed(reason: actionText(language, "Запит скасовано. Уже розпочата дія могла виконатися.", "Request cancelled. An action already started may have completed."))
    }
    private func execute(_ action: Action, language: String, dictationToken: UUID?) async throws -> CommandOutcome {
        switch action {
        case .openApp(let name), .activateApp(let name), .quitApp(let name):
            guard let url = await workspace.resolveApplication(name) else {
                return .failed(reason: actionText(language, "Програму «\(name)» не знайдено. Уточніть назву.", "Application ‘\(name)’ was not found. Check its name."))
            }
            try Task.checkCancellation()
            let success: Bool
            let summary: String
            switch action {
            case .openApp:
                success = try await workspace.openApplication(url)
                summary = actionText(language, "Програму «\(name)» відкрито.", "Opened ‘\(name)’." )
            case .activateApp:
                success = try await workspace.activateApplication(url)
                summary = actionText(language, "Програму «\(name)» активовано.", "Activated ‘\(name)’." )
            default:
                success = try await workspace.quitApplication(url)
                summary = actionText(language, "Програму «\(name)» закрито.", "Closed ‘\(name)’." )
            }
            return success ? .done(summary: summary) : .failed(reason: actionText(language, "Програма не підтвердила дію. Перевірте, чи немає відкритого діалогу або незбережених змін.", "The application did not confirm the action. Check for dialogs or unsaved changes."))
        case .openURL(let raw):
            return try await openWeb(WebActions.validatedURL(raw), language: language)
        case .webSearch(let query):
            return try await openWeb(WebActions.searchURL(query), language: language)
        case .windowMinimize, .windowMaximize, .windowLeftHalf, .windowRightHalf, .windowMinimizeAll:
            if let windows { return await windows.perform(action, language: language) }
            return .failed(reason: actionText(language, "Керування вікнами не підключено.", "Window control is not connected."))
        case .tabNew, .noteNew, .mediaPlayPause, .tabSelect, .tabReopen, .tabPrevious, .tabNext:
            if let shortcuts { return await shortcuts.perform(action, language: language) }
            return .failed(reason: actionText(language, "Швидкі клавіші не підключено.", "Shortcuts are not connected."))
        case .tabCloseActive, .tabCloseLast, .uiSnapshot, .uiPress, .uiSetValue:
            if let uiElements { return await uiElements.perform(action, language: language) }
            return .failed(reason: actionText(language, "Керування елементами вікна не підключено.", "Window element control is not connected."))
        case .runShortcut:
            if let appleShortcuts { return await appleShortcuts.perform(action, language: language) }
            return .failed(reason: actionText(language, "Apple Shortcuts не підключено.", "Apple Shortcuts is not connected."))
        case .volumeSet, .volumeStep, .mute:
            if let audioOutput { return await audioOutput.perform(action, language: language) }
            return .failed(reason: actionText(language, "Керування звуком не підключено.", "Sound control is not connected."))
        case .dictate(let text):
            if let dictation { return await dictation.insert(text, token: dictationToken, language: language) }
            return .failed(reason: actionText(language, "Диктування не підключено.", "Dictation is not connected."))
        }
    }
    private func openWeb(_ url: URL, language: String) async throws -> CommandOutcome {
        try Task.checkCancellation()
        let accepted = try await workspace.openWebURL(url)
        return accepted ? .done(summary: actionText(language, "Посилання передано браузеру.", "The link was handed to the browser.")) : .failed(reason: actionText(language, "Браузер не прийняв посилання.", "The browser did not accept the link."))
    }
}
