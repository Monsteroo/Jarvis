import AppKit

extension JarvisApp {
    // MARK: Spoken replies


    /// Speaks a short reply with the chosen voice. Wake detection is paused
    /// for the whole reply and a short tail, so Jarvis never hears itself.
    func speak(_ text: String, language: String) {
        queuedSpeech.removeAll()
        guard store.spokenReplies, !store.machine.busy else { return }
        let voiceID = language == "en" ? store.voiceEN : store.voiceUK
        guard store.machine.beginSpeaking() else { return }
        logEvent("speak", ["text": text, "language": language])
        speechToken += 1
        enableEscape()
        showHUD()
        if !voice.speak(text, language: language, localVoiceID: voiceID, cloud: cloudPlan()) {
            store.machine.finishSpeaking()
            disableEscape()
        }
    }

    func stopSpeaking() {
        queuedSpeech.removeAll()
        guard store.machine.speaking else { return }
        speechToken += 1
        voice.stop()
        store.machine.finishSpeaking()
        disableEscape()
    }


    /// Lets "Хвилинку, сер" or the previous sentence finish first.
    func speakAfterCurrent(_ text: String, language: String) {
        if store.machine.speaking && voice.isSpeaking { queuedSpeech.append((text, language)) } else { speak(text, language: language) }
    }

    func speechEnded() {
        if !queuedSpeech.isEmpty {
            let next = queuedSpeech.removeFirst()
            speechToken += 1
            let voiceID = next.language == "en" ? store.voiceEN : store.voiceUK
            if store.machine.speaking { logEvent("speak", ["text": next.text, "language": next.language, "after_acknowledgment": true]) }
            if store.machine.speaking, voice.speak(next.text, language: next.language, localVoiceID: voiceID, cloud: cloudPlan()) { return }
        }
        speechToken += 1
        let token = speechToken
        // Room echo of the last syllable must not reach the detector.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, token == self.speechToken, self.store.machine.speaking else { return }
            self.store.machine.finishSpeaking()
            self.disableEscape()
        }
    }


    /// ElevenLabs only when the user enabled it and a key exists (environment
    /// variable or Keychain). The key is read once and kept in memory.
    func cloudPlan() -> SpeechOutput.CloudPlan? {
        guard store.cloudVoiceEnabled else {
            store.cloudStatus = "ElevenLabs вимкнено перемикачем — відповідає голос macOS."
            return nil
        }
        if cachedCloudKey == nil, keysLoaded {
            cachedCloudKey = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"] ?? KeychainSecret.read(KeychainSecret.elevenLabs)
        }
        guard let key = cachedCloudKey, !key.isEmpty else {
            store.cloudStatus = keysLoaded ? "Немає ключа ElevenLabs — відповідає голос macOS."
                : "Ключ ElevenLabs ще читається з Keychain — поки відповідає голос macOS."
            return nil
        }
        return SpeechOutput.CloudPlan(voiceID: store.elevenVoiceID, apiKey: key, monthlyCharacterLimit: store.cloudCharacterLimit)
    }

    func cloudResult(_ reason: String?, characters: Int, seconds: Double) {
        store.refreshCloudUsage()
        store.cloudStatus = reason.map { "Відповів голос macOS: \($0)." }
            ?? String(format: "Відповів ElevenLabs, звук отримано за %.2f с.", seconds)
        wakeTrace(String(format: "cloud tts %@ chars=%d %.2f s", reason == nil ? "ok" : "fallback", characters, seconds))
        logEvent("voice", ["engine": reason != nil ? "macos" : (characters == 0 ? "elevenlabs-cached" : "elevenlabs"),
                           "request_s": Self.rounded(seconds), "fallback_reason": reason ?? NSNull()])
    }

    func saveCloudKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if KeychainSecret.save(trimmed, KeychainSecret.elevenLabs) {
            cachedCloudKey = trimmed
            voice.resetCloudPause()
            store.hasCloudKey = true
            store.cloudVoiceEnabled = true // saving a key means "use ElevenLabs"
            store.cloudStatus = "Ключ збережено в Keychain."
        } else {
            store.cloudStatus = "Не вдалося зберегти ключ у Keychain."
        }
    }

    func deleteCloudKey() {
        KeychainSecret.delete(KeychainSecret.elevenLabs)
        cachedCloudKey = nil
        store.hasCloudKey = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"] != nil
        store.cloudStatus = "Ключ видалено з Keychain."
    }

    func previewVoice(_ language: String) {
        if store.machine.speaking { stopSpeaking() }
        let wasEnabled = store.spokenReplies
        store.spokenReplies = true // preview works even in text-only mode
        speak(SpeechOutput.sample(for: language), language: language)
        store.spokenReplies = wasEnabled
    }
}
