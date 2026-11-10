import Foundation

/// Shared, UI-independent state of one voice turn. The main window, HUD and
/// status menu all render this value; only the app controller mutates it, on
/// the main thread.
enum VoicePhase: Equatable {
    case loadingModel
    case modelUnavailable
    case microphoneOff
    case ready
    case recording
    case transcribing
    case result
    case error
    /// Idle with voice activation armed: waiting for the word "Jarvis".
    case wakeListening
    /// A spoken reply is playing; wake detection is paused meanwhile.
    case speaking
    // Reserved until the action executor is integrated.
    case executing

    /// Future capabilities that must never be presented as working yet.
    static let unavailable: Set<VoicePhase> = [.executing]
}

enum ModelStatus: Equatable { case loading, ready, failed }

struct VoiceMachine: Equatable {
    private(set) var phase: VoicePhase = .loadingModel
    private(set) var model: ModelStatus = .loading
    private(set) var microphoneEnabled = false
    /// The user explicitly enabled activation by the word "Jarvis".
    private(set) var wakeEnabled = false
    /// Increases on every new recording and on every invalidation, so a late
    /// callback from a cancelled turn can never be applied to a newer one.
    private(set) var turn = 0
    private(set) var transcript = ""
    private(set) var message = ""
    private(set) var timedOut = false
    /// Jarvis is speaking: the wake detector must not listen (self-trigger).
    private(set) var speaking = false

    var busy: Bool { phase == .recording || phase == .transcribing }
    var canRecord: Bool { microphoneEnabled && model == .ready && !busy }
    /// The wake detector may listen only in this state.
    var wakeArmed: Bool { wakeEnabled && canRecord && !speaking }

    mutating func modelLoading() {
        invalidate()
        model = .loading
        settle()
    }

    mutating func modelLoaded(_ ok: Bool) {
        model = ok ? .ready : .failed
        if !busy && phase != .result && phase != .error { settle() }
    }

    mutating func setMicrophone(enabled: Bool) {
        microphoneEnabled = enabled
        message = ""
        if !enabled {
            wakeEnabled = false // mic-off closes every capture path
            invalidate()
        }
        if !busy { settle() }
    }

    /// Voice activation requires the microphone to be enabled first.
    mutating func setWake(enabled: Bool) {
        guard !enabled || microphoneEnabled else { return }
        wakeEnabled = enabled
        message = ""
        if !busy && (phase == .ready || phase == .wakeListening) { settle() }
    }

    /// Returns the new turn id, or nil when recording is not allowed.
    mutating func beginRecording() -> Int? {
        guard canRecord else { return nil }
        turn += 1
        phase = .recording
        timedOut = false
        message = ""
        return turn
    }

    @discardableResult
    mutating func beginTranscribing(turn id: Int, timedOut: Bool) -> Bool {
        guard id == turn, phase == .recording else { return false }
        phase = .transcribing
        self.timedOut = timedOut
        return true
    }

    /// `text == nil` means a recognition failure. Stale turns are ignored.
    @discardableResult
    mutating func finishTranscription(turn id: Int, text: String?) -> Bool {
        guard id == turn, phase == .transcribing else { return false }
        if let text {
            transcript = text
            phase = .result
            message = text.isEmpty ? "Мовлення не знайдено. Спробуйте ще раз." : ""
        } else {
            phase = .error
            message = "Помилка локального розпізнавання. Спробуйте ще раз."
        }
        return true
    }

    /// Starts a spoken reply. Not while recording or transcribing.
    @discardableResult
    mutating func beginSpeaking() -> Bool {
        guard !busy else { return false }
        speaking = true
        phase = .speaking
        return true
    }

    /// Speech ended or was stopped. The transcript and message stay visible.
    mutating func finishSpeaking() {
        guard speaking else { return }
        speaking = false
        if phase == .speaking { settle() }
    }

    /// Too-short audio and similar non-errors: return to idle with a hint.
    mutating func abandon(turn id: Int, message: String) {
        guard id == turn, busy else { return }
        invalidate()
        settle()
        self.message = message
    }

    /// Cancel, mic-off, sleep, inactive session, quit.
    mutating func cancel(message: String) {
        let wasBusy = busy
        invalidate()
        settle()
        if wasBusy || !message.isEmpty { self.message = message }
    }

    mutating func fail(message: String) {
        invalidate()
        phase = .error
        self.message = message
    }

    private mutating func invalidate() {
        if busy { turn += 1 }
        speaking = false
        phase = .ready // temporary; settle() picks the real idle phase
    }

    private mutating func settle() {
        switch model {
        case .loading: phase = .loadingModel
        case .failed: phase = .modelUnavailable
        case .ready: phase = speaking ? .speaking : (microphoneEnabled ? (wakeEnabled ? .wakeListening : .ready) : .microphoneOff)
        }
    }
}
