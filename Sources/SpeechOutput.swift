import AVFoundation

/// Spoken replies: an ElevenLabs voice when the user enabled it and gave a key
/// (only the reply text is sent), otherwise a macOS voice installed on this
/// Mac. Microphone audio never leaves the Mac. The app pauses wake detection
/// while this speaks so Jarvis never hears itself.
/// Used from the main thread only.
final class SpeechOutput: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate, @unchecked Sendable {
    struct Voice: Identifiable, Equatable {
        let id: String
        let name: String
        let language: String
        let male: Bool
        let quality: Int   // 1 default, 2 enhanced, 3 premium

        var label: String {
            let tier = quality == 3 ? " · Premium" : (quality == 2 ? " · Enhanced" : "")
            return "\(name) (\(language))\(tier)\(male ? "" : " · жіночий")"
        }
    }

    /// Male voices for "uk" or "en", better quality first (the user chose a
    /// male voice for Jarvis). Only when a language has no male voice at all
    /// (Ukrainian on stock macOS) are the others offered, labelled as such.
    /// Novelty voices (Bells, Zarvox…) are left out.
    static func voices(for language: String) -> [Voice] {
        let all = installedVoices(for: language)
        let male = all.filter(\.male)
        return male.isEmpty ? all : male
    }

    private static func installedVoices(for language: String) -> [Voice] {
        let novelty: Set<String> = ["Albert", "Bad News", "Bahh", "Bells", "Boing", "Bubbles", "Cellos", "Good News", "Jester",
                                    "Organ", "Superstar", "Trinoids", "Whisper", "Wobble", "Zarvox", "Junior", "Kathy", "Ralph", "Fred"]
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language + "-") && !novelty.contains($0.name) && !$0.identifier.contains("eloquence") }
            .map { voice in
                Voice(id: voice.identifier, name: voice.name, language: voice.language, male: voice.gender == .male,
                      quality: voice.quality == .premium ? 3 : (voice.quality == .enhanced ? 2 : 1))
            }
            .sorted { a, b in
                if a.male != b.male { return a.male }
                if a.quality != b.quality { return a.quality > b.quality }
                return a.name < b.name
            }
    }

    static func sample(for language: String) -> String {
        language == "en" ? "At your service. Opening the browser now." : "Слухаю. Відкриваю браузер."
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var current: AVSpeechUtterance?
    private var player: AVAudioPlayer?
    private var task: URLSessionDataTask?
    private var generation = 0
    /// Called on main when speech ends naturally or could not be played.
    var onFinish: (() -> Void)?
    /// Cloud outcome on main: nil when ElevenLabs spoke, otherwise why the
    /// macOS voice answered instead. Never contains the reply text or key.
    var onCloudResult: ((_ fallbackReason: String?, _ characters: Int, _ seconds: Double) -> Void)?

    struct CloudPlan {
        let voiceID: String
        let apiKey: String
        /// 0 means no limit of our own: ElevenLabs' own errors decide.
        let monthlyCharacterLimit: Int
    }

    /// After an account-level error (credits used up, bad key) the cloud is
    /// skipped for a while so replies do not wait on a request that will fail.
    private var cloudPausedUntil: TimeInterval = 0
    private static let cloudPause: TimeInterval = 15 * 60
    private var cloudPauseReason = ""

    /// A new key or voice resumes cloud attempts at once.
    func resetCloudPause() { cloudPausedUntil = 0 }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { current != nil || player != nil || task != nil }

    /// Speaks with ElevenLabs when `cloud` is given and allowed, otherwise (or
    /// on any cloud failure) with the macOS voice. Returns false only when
    /// nothing can be spoken at all.
    @discardableResult
    func speak(_ text: String, language: String, localVoiceID: String, cloud: CloudPlan?) -> Bool {
        stop()
        guard !text.isEmpty else { return false }
        guard let cloud else { return speakLocal(text, voiceID: localVoiceID) }
        var ledger = VoiceUsageLedger.load()
        let count = text.count
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= cloudPausedUntil else {
            onCloudResult?(cloudPauseReason, 0, 0)
            return speakLocal(text, voiceID: localVoiceID)
        }
        guard cloud.monthlyCharacterLimit == 0 || ledger.allows(count, limit: cloud.monthlyCharacterLimit, at: Date()) else {
            onCloudResult?("місячний ліміт знаків ElevenLabs вичерпано", 0, 0)
            return speakLocal(text, voiceID: localVoiceID)
        }
        guard let request = ElevenLabsRequest.make(text: text, voiceID: cloud.voiceID, language: language, apiKey: cloud.apiKey) else {
            onCloudResult?("неправильний ID голосу ElevenLabs", 0, 0)
            return speakLocal(text, voiceID: localVoiceID)
        }
        ledger.record(count, at: Date())   // counted when sent; refunded if it fails
        ledger.save()
        let ticket = generation
        let started = ProcessInfo.processInfo.systemUptime
        task = URLSession.shared.dataTask(with: request) { data, response, _ in
            DispatchQueue.main.async {
                guard ticket == self.generation else { return } // stopped meanwhile
                self.task = nil
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                let status = (response as? HTTPURLResponse)?.statusCode
                if status == 200, let data, let player = try? AVAudioPlayer(data: data) {
                    player.delegate = self
                    self.player = player
                    player.play()
                    self.onCloudResult?(nil, count, elapsed)
                    return
                }
                var refund = VoiceUsageLedger.load()
                refund.record(-count, at: Date())
                refund.save()
                let code = status == 200 ? "undecodable_audio" : ElevenLabsRequest.errorCode(data)
                let reason = ElevenLabsRequest.explain(status: status, code: code)
                if ElevenLabsRequest.isLasting(status: status, code: code) {
                    self.cloudPausedUntil = ProcessInfo.processInfo.systemUptime + Self.cloudPause
                    self.cloudPauseReason = reason + " (ElevenLabs пропускається 15 хв)"
                }
                self.onCloudResult?(reason, 0, elapsed)
                if !self.speakLocal(text, voiceID: localVoiceID) { self.onFinish?() }
            }
        }
        task?.resume()
        return true
    }

    private func speakLocal(_ text: String, voiceID: String) -> Bool {
        guard let voice = AVSpeechSynthesisVoice(identifier: voiceID) else { return false }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        current = utterance
        synthesizer.speak(utterance)
        return true
    }

    /// Stops any request, playback or synthesis. The caller updates the UI.
    func stop() {
        generation += 1
        task?.cancel()
        task = nil
        player?.stop()
        player = nil
        if current != nil { synthesizer.stopSpeaking(at: .immediate) }
        current = nil
    }

    private func ended(_ utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            guard utterance === self.current else { return }
            self.current = nil
            self.onFinish?()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { ended(utterance) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { ended(utterance) }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            guard player === self.player else { return }
            self.player = nil
            self.onFinish?()
        }
    }
}
