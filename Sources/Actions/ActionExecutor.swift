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
    private let parser = IntentParser()
    private let registry = ActionRegistry()
    let events = ActionEvents()

    init(workspace: ActionWorkspace) { self.workspace = workspace }
    @MainActor static func live(aliases: AppAliases = .defaults) -> ActionExecutor {
        ActionExecutor(workspace: MacActionWorkspace(aliases: aliases))
    }

    func handle(_ text: String, language: String) async -> CommandOutcome {
        guard language == "uk" || language == "en" else {
            return .failed(reason: "Оберіть українську або англійську мову.")
        }
        guard !Task.isCancelled else { return cancelled(language) }
        guard let action = parser.parse(text, language: language) else { return .notUnderstood }
        do { try registry.validate(action) }
        catch { return .failed(reason: actionText(language, "Некоректні параметри команди.", "Invalid command parameters.")) }
        let turnID = UUID()
        await events.emit(ActionEvent(turnID: turnID, action: action, phase: .started))
        let result: CommandOutcome
        do {
            try Task.checkCancellation()
            result = try await execute(action, language: language)
        } catch is CancellationError { result = cancelled(language) }
        catch { result = .failed(reason: actionText(language, "Не вдалося виконати дію. Перевірте програму й повторіть спробу.", "The action failed. Check the application and try again.")) }
        await events.emit(ActionEvent(turnID: turnID, action: action, phase: .finished(result)))
        return result
    }

    private func cancelled(_ language: String) -> CommandOutcome {
        .failed(reason: actionText(language, "Запит скасовано. Уже розпочата дія могла виконатися.", "Request cancelled. An action already started may have completed."))
    }
    private func execute(_ action: Action, language: String) async throws -> CommandOutcome {
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
        default:
            return .failed(reason: actionText(language, "Цю дію ще не підключено.", "This action is not connected yet."))
        }
    }
    private func openWeb(_ url: URL, language: String) async throws -> CommandOutcome {
        try Task.checkCancellation()
        let accepted = try await workspace.openWebURL(url)
        return accepted ? .done(summary: actionText(language, "Посилання передано браузеру.", "The link was handed to the browser.")) : .failed(reason: actionText(language, "Браузер не прийняв посилання.", "The browser did not accept the link."))
    }
}
