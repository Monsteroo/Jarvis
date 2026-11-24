import AppKit

extension JarvisApp {
    // MARK: Voice activation

    var wakeModelDir: String { projectRoot + "/.runtime/kws/en-2023-06-26" }

    func toggleWake() {
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
    func continueEnablingWake() {
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

    func disableWake(message: String) {
        brain.memory.clear()
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

    func wakeEvent(_ event: WakeListener.Event) {
        switch event {
        case .utterance(let samples, let end, let epoch):
            let segment = Segment(samples: samples, end: end, epoch: epoch, heardAt: ProcessInfo.processInfo.systemUptime)
            screen(segment)
        case .wake(let generation, let prefixConfirmed):
            // The listener already started the command recording atomically.
            // Accept it only if this is still an idle, armed state.
            prewarmBrain()
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

    var canScreen: Bool {
        modelName == "parakeet-uk-v3" && store.machine.wakeArmed && !store.machine.busy
    }

    func screen(_ segment: Segment) {
        guard canScreen, let job = screening.submit(segment) else { return }
        speech.screen(job.element.samples, language: languageCode) { [weak self] heard, elapsed in
            guard let self else { return }
            defer {
                if let next = self.screening.finish(job.ticket) { self.screen(next) }
            }
            guard self.screening.isCurrent(job.ticket), self.canScreen, let heard else { return }
            let stripped = WakeText.stripLeadingWakeWord(heard)
            self.wakeTrace(String(format: "screen %.2f s audio, asr %.2f s, keyword=%@, command chars=%d, first word «%@»",
                                  Double(segment.samples.count) / 16_000, elapsed,
                                  stripped.found ? "yes" : "no", stripped.found ? stripped.text.count : -1,
                                  WakeText.firstWord(heard)))
            guard stripped.found else { return }
            if stripped.text.isEmpty {
                self.wake.startCommand(after: segment.end, epoch: segment.epoch)
                return
            }
            self.presentScreenedCommand(stripped.text, segment: segment, asrSeconds: elapsed)
        }
    }

    /// The whole «Джарвіс, <команда>» phrase was already heard and recognised.
    func presentScreenedCommand(_ text: String, segment: Segment, asrSeconds: Double) {
        prewarmBrain()
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

    func acknowledge() {
        guard store.acknowledgmentSound else { return }
        chime.play()
    }

    func restartMonitoring(reason: Error) {
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
    func suspendCapture(message: String) {
        cancelSession(message: message)
        if store.machine.wakeEnabled && audio.isMonitoring {
            resumeWakeOnWake = true
            wake.stop()
            audio.stopMonitoring()
        }
    }

    func resumeCapture() {
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
}
