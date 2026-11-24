import AppKit

extension JarvisApp {
    // MARK: Diagnostics

    func toggleDiagnostic() {
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

    func revealDiagnostic() {
        if let url = store.diagnosticURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func copyTranscript() {
        guard !store.machine.transcript.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.machine.transcript, forType: .string)
    }

    // MARK: Measurement mode

    func setMeasuring(_ on: Bool) {
        guard !store.machine.busy else { return }
        store.measuring = on
        refreshMeasurement()
    }

    func currentPrompt() -> MeasurementSession.Current? { measurement.current }

    func refreshMeasurement() {
        guard store.measuring else {
            store.canSkipPrompt = false
            return
        }
        let state = measurement.refresh(model: modelName, language: languageCode)
        store.measurementPrompt = state.prompt
        store.canSkipPrompt = state.canSkip
    }

    func skipPrompt() {
        guard !store.machine.busy, let current = currentPrompt() else { return }
        logMeasurement(current, model: modelName, languageSetting: languageCode, transcript: "",
                       status: .skipped, timedOut: false, audio: 0, whisper: 0, response: 0)
    }

    func logMeasurement(_ current: MeasurementSession.Current, model: String, languageSetting: String,
                                transcript: String, status: MeasurementRecord.Status, timedOut: Bool,
                                audio: Double, whisper: Double, response: Double) {
        let record = MeasurementRecord(
            timestamp: ISO8601DateFormatter().string(from: Date()), model: model, languageSetting: languageSetting,
            pass: current.progress.pass, promptIndex: current.progress.index, promptLanguage: current.prompt.language,
            expected: current.prompt.text, transcript: transcript, status: status, timedOut: timedOut,
            audioSeconds: audio, whisperSeconds: whisper, responseSeconds: response)
        do { try measurement.append(record) } catch {
            store.measurementPrompt = "Не вдалося записати вимір: \(error.localizedDescription)"
            return
        }
        refreshMeasurement()
    }
}
