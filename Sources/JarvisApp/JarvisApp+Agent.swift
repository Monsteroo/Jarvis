import AppKit

extension JarvisApp {
    // MARK: AI agent (Goose + OpenAI; any action needs native one-time approval)

    var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Jarvis")
    }
    /// Both executables come from this app bundle only, never from settings or the model.
    var gooseExecutable: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/goose-acp") }
    var helperExecutable: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/JarvisMCPHelper") }

    /// Reads both API keys off the main thread, once, at launch (APIKeyStore).
    func loadKeys() {
        keys.load { [weak self] in
            guard let self else { return }
            self.store.hasOpenAIKey = self.keys.hasCachedKey(.openAI)
            self.store.hasCloudKey = self.keys.hasCachedKey(.elevenLabs)
            if self.store.hasOpenAIKey, self.agentParts == nil, let parts = try? self.agentComponents() {
                self.agentParts = parts
                self.refreshAgentBudget()
            }
        }
    }

    func openAIKey() -> String? { keys.key(.openAI) }

    var agentAvailable: Bool {
        store.agentEnabled && FileManager.default.isExecutableFile(atPath: gooseExecutable.path)
            && FileManager.default.isExecutableFile(atPath: helperExecutable.path) && openAIKey() != nil
    }

    /// One broker/ledger/agent for the app; rebuilt only when the model changes.
    func agentComponents() throws -> (agent: BudgetedGooseAgent, broker: AgentActionBroker, ledger: BudgetLedger, model: String) {
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

    func cancelAgent() {
        agentTask?.cancel()
        agentTask = nil
        MainActor.assumeIsolated { executor.clearUISnapshots() }
        if let snapshotConsent { MainActor.assumeIsolated { snapshotConsent.cancel() } }
        snapshotConsent = nil
        if let approval { MainActor.assumeIsolated { approval.dismiss() } } // also cancels the broker turn
        approval = nil
    }

    func runAgent(_ text: String, turn id: Int, language: String) {
        cancelAgent()
        let en = language == "en"
        guard let key = openAIKey(), let parts = try? agentComponents() else {
            finishRequest(turn: id)
            setActionStage(.failed, note: store.stages.actionNote)
            store.actionMessage = en ? "The AI agent is not configured." : "Розумний агент не налаштований."
            return
        }
        beginRequest(turn: id, phase: .agent)
        let voiceTurn = UUID()
        startActionStage(turn: id, language: language, ai: true)
        store.actionMessage = en ? "Thinking…" : "Думаю…"
        let context = AgentPlanningContext(broker: parts.broker, turn: voiceTurn, helperExecutable: helperExecutable)
        let started = ProcessInfo.processInfo.systemUptime
        // The first answer takes seconds: Jarvis acknowledges at once, in character.
        let acknowledged = store.spokenReplies
        if acknowledged {
            acknowledgmentIndex += 1
            speak(AgentPersona.acknowledgment(language: language, index: acknowledgmentIndex), language: language)
        }
        let confirmActions = store.confirmAgentActions
        let request = AgentPersona.prompt(for: text, language: language, acknowledged: acknowledged, confirmActions: confirmActions)
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
                // The reply is ready; the action stage waits for real outcomes (below).
                let aiNote = answer.cost.map { String(format: "AI %.1f с · $%.4f", seconds, Double($0.micros) / 1_000_000) }
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
                var spoken = reply.isEmpty ? nil : AgentPersona.spokenPart(reply)
                let turnPlans = plans.filter { $0.turn == voiceTurn }
                let mustConfirm = confirmActions || turnPlans.contains {
                    if case .runShortcut = $0.action { return true }
                    return self.executor.effectivePolicy(for: $0.action) == .confirmation
                }
                self.updateActionStage(turn: id) {
                    $0.replyReady(aiNote: aiNote)
                    if !turnPlans.isEmpty { $0.expect(turnPlans.map(\.id), approval: mustConfirm) }
                }
                if turnPlans.isEmpty {
                    self.finishRequest(turn: id)
                } else if !mustConfirm {
                    // Owner decision 24.11.2026: no review panel for safe immediate actions.
                    // The native side still approves and commits through the broker (one-time token);
                    // the model has no approve/commit path. Esc cancels this task and the broker turn.
                    let failure = await self.runPlansAtOnce(turnPlans, broker: parts.broker, turn: id, language: language)
                    self.updateActionStage(turn: id) { $0.settle() } // plans after a failure did not run
                    guard !Task.isCancelled, self.store.machine.turn == id else { return }
                    self.finishRequest(turn: id)
                    if let failure { spoken = failure }
                } else {
                    self.beginRequest(turn: id, phase: .approval)
                    let controller = AgentApprovalController(broker: parts.broker, turn: voiceTurn, language: language,
                        onEnd: { [weak self] in
                            guard let self else { return }
                            // Plans with no outcome were rejected, expired or cancelled.
                            self.updateActionStage(turn: id) { $0.settle() }
                            self.finishRequest(turn: id)
                        }) { [weak self] plan, outcome in
                        self?.agentPlanFinished(plan, outcome, turn: id, language: language)
                    }
                    self.approval = controller
                    await controller.show()
                }
                guard !Task.isCancelled, self.store.machine.turn == id else { return }
                self.agentTask = nil
                if let spoken { self.speakAfterCurrent(spoken, language: language) }
            } catch {
                guard let self, !Task.isCancelled, self.store.machine.turn == id else { return }
                self.agentTask = nil
                self.finishRequest(turn: id)
                self.setActionStage(.failed, note: "AI")
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

    /// Runs AI-proposed plans in order without the review panel. Returns the
    /// first failure to say aloud, or nil when every action succeeded.
    func runPlansAtOnce(_ plans: [AgentActionPlan], broker: AgentActionBroker, turn id: Int, language: String) async -> String? {
        var summaries: [String] = []
        for plan in plans {
            guard !Task.isCancelled else { return nil }
            let outcome: CommandOutcome
            do {
                let token = try await broker.approve(plan: plan.id)
                outcome = try await broker.commit(plan: plan.id, token: token)
            } catch {
                outcome = .failed(reason: language == "en" ? "The action was cancelled." : "Дію скасовано.")
            }
            logEvent("plan", ["outcome": Self.planLogLabel(plan.action, outcome), "auto": true])
            updateActionStage(turn: id) { $0.resolve(plan.id, Self.actionStep(outcome)) }
            switch outcome {
            case .done(let summary):
                // Window text is for the model only: never shown, spoken or logged.
                summaries.append(Self.isSnapshot(plan.action) ? Self.snapshotReadPhrase(language: language) : summary)
            case .partial(let summary, let details):
                // A snapshot whose history write failed arrives as partial with the window text as summary.
                let shown = Self.isSnapshot(plan.action) ? Self.snapshotReadPhrase(language: language) : summary
                store.actionMessage = shown + " " + details; return shown
            case .failed(let reason): store.actionMessage = reason; return reason
            default: let text = language == "en" ? "The action did not run." : "Дію не виконано."; store.actionMessage = text; return text
            }
        }
        if !summaries.isEmpty { store.actionMessage += (store.actionMessage.isEmpty ? "" : "\n") + summaries.joined(separator: " ") }
        return nil
    }

    /// One approved plan finished (approval panel). The stage combines all plans.
    func agentPlanFinished(_ plan: AgentActionPlan, _ outcome: CommandOutcome, turn id: Int, language: String) {
        logEvent("plan", ["outcome": Self.planLogLabel(plan.action, outcome)])
        updateActionStage(turn: id) { $0.resolve(plan.id, Self.actionStep(outcome)) }
        switch outcome {
        case .done(let summary):
            // Window text is for the model only: never shown, spoken or logged.
            let text = Self.isSnapshot(plan.action) ? Self.snapshotReadPhrase(language: language) : summary
            store.actionMessage = text; speak(text, language: language)
        case .partial(let summary, let details):
            let shown = Self.isSnapshot(plan.action) ? Self.snapshotReadPhrase(language: language) : summary
            store.actionMessage = shown + " " + details; speak(shown, language: language)
        case .failed(let reason):
            store.actionMessage = reason; speak(reason, language: language)
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

    func refreshAgentBudget() {
        guard let ledger = agentParts?.ledger else { return }
        Task { @MainActor [weak self] in
            guard let snapshot = try? await ledger.snapshot() else { return }
            self?.store.agentBudget = String(format: "Цього місяця: $%.2f з $%.0f", Double(snapshot.committed.micros) / 1_000_000, Double(snapshot.limit.micros) / 1_000_000)
        }
    }

    func saveOpenAIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if keys.save(trimmed, for: .openAI) {
            store.hasOpenAIKey = true
            store.agentStatus = "Ключ OpenAI збережено в Keychain."
        } else {
            store.agentStatus = "Не вдалося зберегти ключ у Keychain."
        }
    }

    func deleteOpenAIKey() {
        keys.delete(.openAI)
        store.hasOpenAIKey = keys.inEnvironment(.openAI)
        store.agentStatus = "Ключ OpenAI видалено з Keychain."
    }
}
