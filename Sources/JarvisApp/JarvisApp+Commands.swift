import AppKit

extension JarvisApp {
    // MARK: Actions (ChatGPT's ActionExecutor, one instance)

    /// Before the HUD appears: remember the focused text field for dictation.
    func captureFocus() {
        dictationToken = MainActor.assumeIsolated { try? executor.captureDictationTarget() }
        wakeTrace("focus field=\(dictationToken != nil)") // a flag only, no app names or text
    }

    func refreshEscape() {
        if store.canCancel { enableEscape() } else { disableEscape() }
    }
    func beginRequest(turn id: Int, phase: RequestActivity.Phase) {
        store.requestActivity.begin(turn: id, phase: phase)
        refreshEscape()
        showHUD()
    }
    func finishRequest(turn id: Int) {
        store.requestActivity.finish(turn: id)
        refreshEscape()
        if !store.canCancel { hideHUD(after: 3.5) }
    }

    func cancelCommand() {
        // Before the panel closes: a cancelled request shows "cancelled", never running or done.
        updateActionStage(turn: store.machine.turn) { $0.cancel() }
        commandTask?.cancel()
        commandTask = nil
        MainActor.assumeIsolated { executor.clearUISnapshots() }
        cancelAgent()
        store.requestActivity.cancel()
        refreshEscape()
    }

    /// Runs a recognised command through the typed executor and reports the
    /// real outcome. A newer turn or cancel makes a late result invisible.
    func runCommand(_ text: String, turn id: Int, language: String) {
        cancelCommand()
        guard !text.isEmpty else { return }
        if brainAvailable, let name = Self.appName(in: IntentParser().parse(text, language: language)),
           !MacContext.resolvable(name, installed: MacContext.installedApps(), running: [],
                                  aliases: Array(AppAliases.defaults.bundleIDs.keys)) {
            // "відкрий календар", "YouTube в Google Chrome", "антигравіті": the
            // simple rules guessed an application name that does not exist.
            lastCommandText = text
            lastCommandTurn = id
            logEvent("action", ["result": "unresolved app", "name": name, "next": "brain"])
            runBrain(text, turn: id, language: language)
            return
        }
        beginRequest(turn: id, phase: .command)
        let token = dictationToken
        dictationToken = nil
        lastCommandText = text
        lastCommandTurn = id
        startActionStage(turn: id, language: language, ai: false)
        let executor = self.executor
        let started = ProcessInfo.processInfo.systemUptime
        commandTask = Task { @MainActor [weak self] in
            let outcome = await executor.handle(text, language: language, dictationToken: token)
            guard let self, !Task.isCancelled, self.store.machine.turn == id, !self.store.machine.busy else { return }
            self.commandTask = nil
            self.present(outcome, turn: id, language: language, seconds: ProcessInfo.processInfo.systemUptime - started)
        }
    }

    func present(_ outcome: CommandOutcome, turn id: Int, language: String, seconds: Double) {
        let en = language == "en"
        let spoken: String
        switch outcome {
        case .done(let summary):
            setActionStage(.done, note: String(format: "%.2f с", seconds))
            store.actionMessage = summary
            spoken = summary
        case .partial(let summary, let details):
            setActionStage(.failed, note: en ? "partly" : "частково")
            store.actionMessage = summary + " " + details
            spoken = summary + " " + details
        case .failed(let reason):
            setActionStage(.failed, note: en ? "failed" : "не виконано")
            store.actionMessage = reason
            spoken = reason
        case .needsApproval(let request):
            let broker = AgentActionBroker(executor: LocalTypedActionRunner(executor))
            let voiceTurn = request.turnID
            beginRequest(turn: id, phase: .approval)
            store.actionMessage = request.summary
            Task { @MainActor [weak self] in
                guard let self else { return }
                let controller = AgentApprovalController(broker: broker, turn: voiceTurn, language: language,
                    onEnd: { [weak self] in
                        guard let self else { return }
                        self.updateActionStage(turn: id) { $0.settle() }
                        self.finishRequest(turn: id)
                    }) { [weak self] plan, outcome in
                    self?.agentPlanFinished(plan, outcome, turn: id, language: language)
                }
                self.approval = controller
                await broker.begin(turn: voiceTurn, language: language)
                guard let plan = try? await broker.propose(request.action, turn: voiceTurn) else {
                    self.setActionStage(.failed, note: en ? "rejected" : "відхилено")
                    self.finishRequest(turn: id)
                    return
                }
                guard self.store.machine.turn == id else { return }
                self.updateActionStage(turn: id) { $0.expect([plan.id], approval: true) }
                await controller.show()
            }
            speak(en ? "It awaits your confirmation on screen, sir." : "Чекає вашого підтвердження на екрані, сер.", language: language)
            return
        case .notUnderstood where brainAvailable:
            logEvent("action", ["result": "notUnderstood", "next": "brain", "seconds": Self.rounded(seconds)])
            runBrain(lastCommandText, turn: lastCommandTurn, language: language)
            return
        case .notUnderstood where agentAvailable:
            logEvent("action", ["result": "notUnderstood", "next": "agent", "seconds": Self.rounded(seconds)])
            runAgent(lastCommandText, turn: lastCommandTurn, language: language)
            return
        case .notUnderstood:
            setActionStage(.failed, note: en ? "not understood" : "не зрозумів")
            store.actionMessage = en ? "I don't know this command yet. Try “open Safari” or “volume up”."
                                     : "Поки не знаю такої команди. Спробуйте «відкрий Safari» або «зроби гучніше»."
            spoken = en ? "I don't know this command yet." : "Поки не знаю такої команди."
        }
        wakeTrace(String(format: "action %@ %.2f s", "\(outcome)".prefix(12).description, seconds))
        logEvent("action", ["result": "\(outcome)", "message": store.actionMessage, "seconds": Self.rounded(seconds)])
        finishRequest(turn: id)
        speak(spoken, language: language)
    }
}
