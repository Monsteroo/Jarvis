import AppKit

extension JarvisApp {
    // MARK: Action stage (real executor results only, audit R6)

    /// A new request of turn `id` owns the action stage from now on.
    func startActionStage(turn id: Int, language: String, ai: Bool) {
        actionStageTurn = id
        actionStage = ActionStageTracker(language: language)
        actionStage.begin(ai: ai)
        showActionStage()
    }

    /// Applies a change from turn `id`; a stale or finished turn is ignored.
    func updateActionStage(turn id: Int, _ change: (inout ActionStageTracker) -> Void) {
        guard actionStageTurn == id, store.machine.turn == id else { return }
        change(&actionStage)
        showActionStage()
    }

    /// A direct, final result (local command, AI error): the tracker lets go.
    func setActionStage(_ state: StageState, note: String?) {
        actionStageTurn = nil
        store.stages.action = state
        store.stages.actionNote = note
    }

    private func showActionStage() {
        store.stages.action = actionStage.state
        store.stages.actionNote = actionStage.note
    }

    static func actionStep(_ outcome: CommandOutcome) -> ActionStageTracker.Step {
        if case .done = outcome { return .done }
        return .failed // partial, failed, needsApproval, notUnderstood
    }

    static func isSnapshot(_ action: Action) -> Bool {
        switch action {
        case .uiSnapshot, .clipboardRead: return true
        default: return false
        }
    }

    /// Said and shown instead of raw window/clipboard text, which is for the model only.
    static func snapshotReadPhrase(for action: Action, language: String) -> String {
        if case .clipboardRead = action {
            return language == "en" ? "Clipboard read." : "Буфер обміну прочитано."
        }
        return language == "en" ? "Window read." : "Вікно прочитано."
    }

    /// Log label of a plan outcome; never contains window or clipboard text.
    static func planLogLabel(_ action: Action, _ outcome: CommandOutcome) -> String {
        guard isSnapshot(action) else { return "\(outcome)" }
        let kind: String = { if case .clipboardRead = action { return "clipboard" }; return "snapshot" }()
        switch outcome {
        case .done(let text): return "done (\(kind), \(text.count) chars)"
        case .partial: return "partial (\(kind))"
        case .failed(let reason): return "failed: \(reason)"
        default: return "\(outcome)"
        }
    }
}
