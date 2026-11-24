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

    func currentPrompt() -> (progress: MeasurementProgress, prompt: Prompt)? {
        guard let progress, !progress.finished, progress.index < prompts.count else { return nil }
        return (progress, prompts[progress.index])
    }

    func refreshMeasurement() {
        guard store.measuring else {
            store.canSkipPrompt = false
            return
        }
        if prompts.isEmpty {
            let path = projectRoot + "/docs/benchmarks/prompts.txt"
            prompts = PromptSet.parse((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
            measurementLog = MeasurementLog(url: URL(fileURLWithPath: projectRoot + "/.runtime/measurements/uk-en-v1.jsonl"))
        }
        guard !prompts.isEmpty, let measurementLog else {
            store.measurementPrompt = "Не знайдено docs/benchmarks/prompts.txt."
            store.canSkipPrompt = false
            return
        }
        progress = MeasurementProgress.next(records: measurementLog.records(), model: modelName,
                                            languageSetting: languageCode, promptCount: prompts.count)
        if let current = currentPrompt() {
            store.measurementPrompt = "Прохід \(current.progress.pass)/\(MeasurementProgress.passes) · \(current.progress.index + 1)/\(prompts.count) · [\(current.prompt.language)] \(current.prompt.text)"
            store.canSkipPrompt = true
        } else {
            store.measurementPrompt = "Усі \(MeasurementProgress.passes) проходи для \(modelName) / \(languageCode) записано. Запустіть scripts/analyze_measurements.py."
            store.canSkipPrompt = false
        }
    }

    func skipPrompt() {
        guard !store.machine.busy, let current = currentPrompt() else { return }
        logMeasurement(current, model: modelName, languageSetting: languageCode, transcript: "",
                       status: .skipped, timedOut: false, audio: 0, whisper: 0, response: 0)
    }

    func logMeasurement(_ current: (progress: MeasurementProgress, prompt: Prompt), model: String, languageSetting: String,
                                transcript: String, status: MeasurementRecord.Status, timedOut: Bool,
                                audio: Double, whisper: Double, response: Double) {
        let record = MeasurementRecord(
            timestamp: ISO8601DateFormatter().string(from: Date()), model: model, languageSetting: languageSetting,
            pass: current.progress.pass, promptIndex: current.progress.index, promptLanguage: current.prompt.language,
            expected: current.prompt.text, transcript: transcript, status: status, timedOut: timedOut,
            audioSeconds: audio, whisperSeconds: whisper, responseSeconds: response)
        do { try measurementLog?.append(record) } catch {
            store.measurementPrompt = "Не вдалося записати вимір: \(error.localizedDescription)"
            return
        }
        refreshMeasurement()
    }
}
