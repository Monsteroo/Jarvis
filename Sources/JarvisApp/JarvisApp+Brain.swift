import AppKit

extension JarvisApp {
    // MARK: Brain (direct OpenAI with memory; owner decision D1, 24.11.2026)


    var brainAvailable: Bool { store.agentEnabled && store.brainEnabled && openAIKey() != nil }

    static func appName(in action: Action?) -> String? {
        switch action {
        case .openApp(let name)?, .quitApp(let name)?, .activateApp(let name)?: return name
        default: return nil
        }
    }

    /// Opens the TLS/HTTP2 connection while the owner is still speaking, so the
    /// real request does not pay the handshake. Sends no key and no text.
    func prewarmBrain() {
        let now = ProcessInfo.processInfo.systemUptime
        guard brainAvailable, now - lastPrewarm > 20 else { return }
        lastPrewarm = now
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.httpMethod = "HEAD"
        URLSessionBrainTransport.session.dataTask(with: request).resume()
    }

    func runBrain(_ text: String, turn id: Int, language: String) {
        cancelAgent()
        let en = language == "en"
        guard let key = openAIKey(), let parts = try? agentComponents() else {
            finishRequest(turn: id)
            setActionStage(.failed, note: store.stages.actionNote)
            store.actionMessage = en ? "The AI is not configured." : "Розумний агент не налаштований."
            return
        }
        beginRequest(turn: id, phase: .agent)
        startActionStage(turn: id, language: language, ai: true)
        store.actionMessage = en ? "Thinking…" : "Думаю…"
        brain.model = store.agentModel
        let confirm = store.confirmAgentActions
        let mac = MacContext.current()
        let system = AgentPersona.brainSystem(language: language, installedApps: mac.installed)
        let context = AgentPersona.brainContext(language: language, apps: mac.line(language: language), shortcuts: executor.allowlistedShortcutNames())
        let voiceTurn = UUID()
        let started = ProcessInfo.processInfo.systemUptime
        brainSpokeTurn = nil
        brainFirstSpeech = nil
        wakeTrace("brain start v\(AgentPersona.brainVersion)")
        let thinking = JarvisBrain.needsThinking(text)
        logEvent("brain_start", ["request": text, "model": store.agentModel, "prompt": AgentPersona.brainVersion,
                                 "language": language, "memory_messages": brain.memory.turns.count, "thinking": thinking,
                                 "front_app": mac.frontmost ?? NSNull()])
        // Say "one moment" only if the answer is slow to start.
        let acknowledgment: Task<Void, Never>? = store.spokenReplies ? Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled, self.store.machine.turn == id, self.brainSpokeTurn != id else { return }
            self.acknowledgmentIndex += 1
            self.speak(AgentPersona.acknowledgment(language: language, index: self.acknowledgmentIndex), language: language)
        } : nil
        agentTask = Task { @MainActor [weak self] in
            defer { acknowledgment?.cancel() }
            guard let self else { return }
            await parts.broker.begin(turn: voiceTurn, language: language)
            guard let reservation = try? await parts.ledger.reserve(Money(micros: 20_000)) else {
                guard self.store.machine.turn == id else { return }
                self.agentTask = nil
                self.finishRequest(turn: id)
                self.setActionStage(.failed, note: "AI")
                self.store.actionMessage = en ? "The monthly AI budget is used up." : "Місячний бюджет AI вичерпано."
                self.speak(en ? "My apologies, sir, the monthly AI budget is used up." : "Перепрошую, сер, місячний бюджет AI вичерпано.", language: language)
                return
            }
            let runAction: (Action) async -> JarvisBrain.ToolOutcome = { [weak self] action in
                guard let self else {
                    return .executed(.failed(reason: en ? "The action was cancelled." : "Дію скасовано."))
                }
                do {
                    if case .uiSnapshot = action {
                        // Window text goes to OpenAI: outside the allowlist the owner
                        // allows it on screen first (owner decision 25.11.2026).
                        let outcome: CommandOutcome
                        if confirm || self.executor.effectivePolicy(for: action) == .confirmation {
                            let target = self.executor.describeUIAction(action) ?? (en ? "front window" : "переднє вікно")
                            let allowed = await self.askSnapshotConsent(app: target, request: text, language: language)
                            self.logEvent("snapshot_consent", ["app": target, "allowed": allowed])
                            guard allowed, !Task.isCancelled else {
                                self.logEvent("brain_action", ["action": "uiSnapshot", "outcome": "not allowed"])
                                return .executed(.failed(reason: en
                                    ? "The owner did not allow reading this window. Do not try again in this request."
                                    : "Власник не дозволив читати це вікно. Не пробуй знову в цьому запиті."))
                            }
                            self.store.actionMessage = en ? "Reading window…" : "Читаю вікно…"
                            outcome = await self.executor.uiSnapshotWithOwnerConsent(action, language: language)
                        } else {
                            self.store.actionMessage = en ? "Reading window…" : "Читаю вікно…"
                            outcome = await self.executor.handle(action: action, language: language)
                        }
                        let loggedOutcome: String
                        switch outcome {
                        case .done(let text): loggedOutcome = "done (\(text.count) chars)"
                        case .failed(let reason): loggedOutcome = "failed: \(reason)"
                        default: loggedOutcome = "\(outcome)"
                        }
                        self.logEvent("brain_action", ["action": "uiSnapshot", "outcome": loggedOutcome])
                        return .executed(outcome)
                    }
                    let detail = self.executor.describeUIAction(action)
                    let policy = self.executor.effectivePolicy(for: action)
                    let plan = try await parts.broker.propose(action, turn: voiceTurn, detail: detail)
                    if confirm || policy == .confirmation { return .proposed }
                    let token = try await parts.broker.approve(plan: plan.id)
                    let outcome = try await parts.broker.commit(plan: plan.id, token: token)
                    let actionName: String
                    if case .uiSetValue(let app, let snap, let ref, _) = action {
                        actionName = "uiSetValue(\(app), \(snap), \(ref))"
                    } else {
                        actionName = "\(action)"
                    }
                    self.logEvent("brain_action", ["action": actionName, "outcome": "\(outcome)"])
                    return .executed(outcome)
                } catch {
                    return .executed(.failed(reason: en ? "The action was cancelled." : "Дію скасовано."))
                }
            }
            do {
                let result = try await self.brain.respond(
                    to: text, language: language, system: system, context: context, apiKey: key, thinking: thinking,
                    execute: { [weak self] action in
                        let outcome = await runAction(action)
                        // Only real executor results move the action stage.
                        if case .executed(let real) = outcome {
                            self?.updateActionStage(turn: id) { $0.record(Self.actionStep(real)) }
                        }
                        return outcome
                    },
                    onSentence: { [weak self] sentence in self?.brainSay(sentence, turn: id, language: language, started: started) })
                try? await parts.ledger.settle(reservation, actual: Money(micros: result.usage.costMicros), complete: result.usageComplete)
                guard !Task.isCancelled, self.store.machine.turn == id else { return }
                acknowledgment?.cancel()
                let seconds = ProcessInfo.processInfo.systemUptime - started
                if let spoken = result.spoken { self.brainSay(spoken, turn: id, language: language, started: started) }
                // The reply is ready; the action stage waits for real outcomes (below).
                let aiNote = String(format: "AI %.1f с · $%.4f", seconds, Double(result.usage.costMicros) / 1_000_000)
                self.store.actionMessage = String(result.reply.prefix(600))
                self.wakeTrace(String(format: "brain ok %.1f s rounds=%d", seconds, result.rounds))
                self.logEvent("brain", ["engine": "brain", "reply": result.reply, "spoken_after": result.spoken ?? NSNull(),
                                        "seconds": Self.rounded(seconds), "first_text_s": Self.rounded(result.firstTextSeconds),
                                        "first_speech_s": Self.rounded(self.brainFirstSpeech), "rounds": result.rounds,
                                        "actions": result.actions.map { "\($0.action) → \($0.result)" },
                                        "prompt_tokens": result.usage.prompt, "cached_tokens": result.usage.cached,
                                        "completion_tokens": result.usage.completion,
                                        "cost_usd": Double(result.usage.costMicros) / 1_000_000, "usage_complete": result.usageComplete])
                self.refreshAgentBudget()
                let plans = await parts.broker.pendingPlans().filter { $0.turn == voiceTurn }
                guard !Task.isCancelled, self.store.machine.turn == id else { return }
                self.updateActionStage(turn: id) {
                    $0.replyReady(aiNote: aiNote)
                    if !plans.isEmpty { $0.expect(plans.map(\.id), approval: true) }
                }
                if !plans.isEmpty {
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
                } else {
                    self.finishRequest(turn: id)
                }
                self.agentTask = nil
            } catch {
                try? await parts.ledger.settle(reservation, actual: nil, complete: false)
                guard !Task.isCancelled, self.store.machine.turn == id else { return }
                acknowledgment?.cancel()
                self.agentTask = nil
                self.finishRequest(turn: id)
                self.setActionStage(.failed, note: "AI")
                let message = Self.brainFailure(error, language: language)
                self.store.actionMessage = message
                self.wakeTrace("brain failed \(error)")
                self.logEvent("brain_error", ["error": "\(error)", "seconds": Self.rounded(ProcessInfo.processInfo.systemUptime - started)])
                self.refreshAgentBudget()
                self.speakAfterCurrent(message, language: language)
            }
        }
    }

    func brainSay(_ text: String, turn id: Int, language: String, started: Double) {
        guard store.machine.turn == id, !text.isEmpty else { return }
        if brainSpokeTurn != id {
            brainSpokeTurn = id
            brainFirstSpeech = ProcessInfo.processInfo.systemUptime - started
        }
        speakAfterCurrent(text, language: language)
    }

    static func brainFailure(_ error: Error, language: String) -> String {
        let en = language == "en"
        switch error {
        case BrainError.http(401, _), BrainError.http(403, _):
            return en ? "My apologies, sir, OpenAI did not accept the key." : "Перепрошую, сер, OpenAI не прийняв ключ."
        case BrainError.http(429, _):
            return en ? "My apologies, sir, OpenAI is busy or the limit is reached." : "Перепрошую, сер, OpenAI перевантажений або ліміт вичерпано."
        case is URLError:
            return en ? "My apologies, sir, there is no connection to OpenAI." : "Перепрошую, сер, немає з'єднання з OpenAI."
        default:
            return en ? "My apologies, sir, the request failed." : "Перепрошую, сер, не вдалося отримати відповідь."
        }
    }

    /// Shows the consent panel and waits for the owner (Esc or 30 s means no).
    @MainActor func askSnapshotConsent(app: String, request: String, language: String) async -> Bool {
        snapshotConsent?.cancel()
        let panel = SnapshotConsentPanel(appName: app, request: request, language: language)
        snapshotConsent = panel
        store.actionMessage = language == "en" ? "Waiting for your permission to read the window." : "Чекаю вашого дозволу прочитати вікно."
        speakAfterCurrent(language == "en" ? "May I read this window, sir? Please answer on screen." : "Дозвольте прочитати вікно, сер. Відповідь на екрані.", language: language)
        let allowed = await panel.ask()
        if snapshotConsent === panel { snapshotConsent = nil }
        return allowed
    }
}
