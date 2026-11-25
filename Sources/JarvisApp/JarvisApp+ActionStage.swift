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
        if case .uiSnapshot = action { return true }
        return false
    }

    /// Said and shown instead of the raw window text, which is for the model only.
    static func snapshotReadPhrase(language: String) -> String {
        language == "en" ? "Window read." : "Вікно прочитано."
    }

    /// Log label of a plan outcome; never contains window text.
    static func planLogLabel(_ action: Action, _ outcome: CommandOutcome) -> String {
        guard isSnapshot(action) else { return "\(outcome)" }
        switch outcome {
        case .done(let text): return "done (snapshot, \(text.count) chars)"
        case .partial: return "partial (snapshot)"
        case .failed(let reason): return "failed: \(reason)"
        default: return "\(outcome)"
        }
    }
}
