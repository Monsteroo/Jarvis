import AppKit
import AVFoundation

extension JarvisApp {
    // MARK: Model

    func setModel(_ index: Int) {
        guard !store.machine.busy, index != store.modelIndex, store.modelTitles.indices.contains(index) else { return }
        store.modelIndex = index
        loadSelectedModel()
    }

    func setLanguage(_ index: Int) {
        guard !store.machine.busy, store.languageTitles.indices.contains(index) else { return }
        screening.invalidate()
        store.languageIndex = index
        refreshMeasurement()
    }

    func loadSelectedModel() {
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

    // MARK: Microphone

    func toggleMicrophone() {
        if store.machine.microphoneEnabled {
            cancelSession(message: "")
            // Full mic-off: wake monitoring stops too and the engine closes.
            brain.memory.clear()
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

    func keyDown() {
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
    func beginTurnUI(_ id: Int) {
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

    func keyUp() {
        let wasRecording = gate.release()
        if wasRecording { finishRecording(timedOut: false) }
    }

    func finishRecording(timedOut: Bool) {
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
                    self.wakeTrace(String(format: "asr done %.2f s, rejected: no leading address, first word «%@»",
                                          elapsed, WakeText.firstWord(heard)))
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

    func stopTimers() {
        clock?.invalidate()
        timeout?.invalidate()
        clock = nil
        timeout = nil
    }

    func cancelSession(message: String) {
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
}
