import Foundation

@main
struct VoiceStateTests {
    static func main() {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            assert(condition(), message)
            count += 1
        }

        var m = VoiceMachine()
        check(m.phase == .loadingModel, "Launch shows model loading, never recording")
        check(m.beginRecording() == nil, "No recording while the model loads")
        m.modelLoaded(true)
        check(m.phase == .microphoneOff, "Microphone is off until the user enables it")
        check(m.beginRecording() == nil, "Mic-off blocks recording")
        m.setMicrophone(enabled: true)
        check(m.phase == .ready, "Ready after explicit enable")

        // Happy path.
        let t1 = m.beginRecording()!
        check(m.phase == .recording, "Press → recording")
        check(m.beginRecording() == nil, "A second press during recording is ignored")
        check(m.beginTranscribing(turn: t1, timedOut: false), "Release → transcribing")
        check(m.phase == .transcribing, "Transcribing phase")
        check(m.beginRecording() == nil, "No recording during inference")
        check(m.finishTranscription(turn: t1, text: "Перемкнись на термінал."), "Result accepted")
        check(m.phase == .result && m.transcript == "Перемкнись на термінал.", "Result shows real text")

        // Cancel during transcription invalidates the late callback.
        let t2 = m.beginRecording()!
        check(t2 != t1, "Every turn gets a new id")
        m.beginTranscribing(turn: t2, timedOut: false)
        m.cancel(message: "Скасовано.")
        check(m.phase == .ready, "Cancel returns to ready")
        check(!m.finishTranscription(turn: t2, text: "пізній текст"), "Stale callback after cancel is ignored")
        check(m.transcript == "Перемкнись на термінал.", "Stale text never replaces the transcript")
        check(m.phase == .ready, "Stale callback does not resurrect a phase")

        // A stale callback must not land in a newer turn.
        let t3 = m.beginRecording()!
        check(!m.beginTranscribing(turn: t2, timedOut: false), "Old turn cannot advance a new recording")
        check(m.phase == .recording, "New recording unaffected")
        m.beginTranscribing(turn: t3, timedOut: true)
        check(m.timedOut, "Timeout is remembered for the UI")
        check(m.finishTranscription(turn: t3, text: nil) && m.phase == .error, "Recognition failure is an error")

        // Mic-off during recording stops the turn.
        let t4 = m.beginRecording()!
        m.setMicrophone(enabled: false)
        check(m.phase == .microphoneOff, "Mic-off is unambiguous")
        check(!m.beginTranscribing(turn: t4, timedOut: false), "Mic-off invalidates the recording")
        check(m.beginRecording() == nil, "Mic-off blocks new recordings")

        // Too-short audio returns to idle without an error.
        m.setMicrophone(enabled: true)
        let t5 = m.beginRecording()!
        m.abandon(turn: t5, message: "Запис надто короткий.")
        check(m.phase == .ready && m.message == "Запис надто короткий.", "Short audio → ready with hint")

        // Model reload invalidates in-flight work; failure is explicit.
        let t6 = m.beginRecording()!
        m.beginTranscribing(turn: t6, timedOut: false)
        m.modelLoading()
        check(m.phase == .loadingModel, "Reload shows loading")
        check(!m.finishTranscription(turn: t6, text: "x"), "Reload invalidates inference")
        m.modelLoaded(false)
        check(m.phase == .modelUnavailable, "Model failure is explicit")
        check(m.beginRecording() == nil, "No recording without a model")

        // Empty result is a result with a hint, not success text.
        m.modelLoaded(true)
        let t7 = m.beginRecording()!
        m.beginTranscribing(turn: t7, timedOut: false)
        m.finishTranscription(turn: t7, text: "")
        check(m.phase == .result && !m.message.isEmpty, "Silence yields 'no speech' hint")

        // Device/permission failure.
        _ = m.beginRecording()!
        m.fail(message: "Мікрофон недоступний.")
        check(m.phase == .error && !m.busy, "Capture failure ends the turn")

        // Future capabilities are never reachable.
        check(VoicePhase.unavailable.contains(.executing), "Executing stays unavailable until actions exist")
        check(!VoicePhase.unavailable.contains(.speaking), "Speaking is a real phase now")
        check(!VoicePhase.unavailable.contains(.wakeListening), "Wake listening is now a real phase")

        // Voice activation by "Jarvis".
        var w = VoiceMachine()
        w.modelLoaded(true)
        w.setWake(enabled: true)
        check(!w.wakeEnabled && w.phase == .microphoneOff, "Wake cannot be enabled while the mic is off")
        w.setMicrophone(enabled: true)
        check(w.phase == .ready && !w.wakeArmed, "Mic on alone does not listen for the wake word")
        w.setWake(enabled: true)
        check(w.phase == .wakeListening && w.wakeArmed, "Explicit enable arms the wake detector")
        let wt = w.beginRecording()!
        check(w.phase == .recording && !w.wakeArmed, "Detector is disarmed during the command")
        w.beginTranscribing(turn: wt, timedOut: false)
        check(!w.wakeArmed, "Detector is disarmed during recognition")
        w.finishTranscription(turn: wt, text: "Відкрий браузер.")
        check(w.phase == .result && w.wakeArmed, "Result keeps the text and re-arms the detector")
        let wt2 = w.beginRecording()!
        w.abandon(turn: wt2, message: "Не почув команди.")
        check(w.phase == .wakeListening && w.message == "Не почув команди.", "No command → back to wake listening")
        let wt3 = w.beginRecording()!
        w.cancel(message: "Скасовано.")
        check(w.phase == .wakeListening, "Cancel returns to wake listening")
        check(!w.beginTranscribing(turn: wt3, timedOut: false), "Cancelled wake turn cannot continue")
        w.setWake(enabled: false)
        check(w.phase == .ready && !w.wakeArmed, "Disabling activation returns to PTT-only ready")
        w.setWake(enabled: true)
        _ = w.beginRecording()!
        w.setMicrophone(enabled: false)
        check(!w.wakeEnabled && w.phase == .microphoneOff && !w.wakeArmed, "Mic-off disables activation and stops the turn")
        w.setMicrophone(enabled: true)
        check(w.phase == .ready, "Re-enabling the mic does not silently re-enable wake listening")
        w.setWake(enabled: true)
        w.modelLoading()
        check(!w.wakeArmed && w.phase == .loadingModel, "No wake listening while the model reloads")
        w.modelLoaded(true)
        check(w.phase == .wakeListening, "Wake listening resumes after the model loads")

        // Spoken replies pause wake detection (no self-trigger).
        var t = VoiceMachine()
        t.modelLoaded(true)
        t.setMicrophone(enabled: true)
        t.setWake(enabled: true)
        let reply = t.beginRecording()!
        check(!t.beginSpeaking(), "No speaking while recording")
        t.beginTranscribing(turn: reply, timedOut: false)
        t.finishTranscription(turn: reply, text: "Відкрий браузер")
        check(t.beginSpeaking() && t.phase == .speaking && t.speaking, "Speaking after a result")
        check(!t.wakeArmed, "Wake is not armed while Jarvis speaks")
        check(t.transcript == "Відкрий браузер", "Transcript stays visible while speaking")
        t.finishSpeaking()
        check(!t.speaking && t.phase == .wakeListening && t.wakeArmed, "Wake resumes after speech")
        t.finishSpeaking()
        check(t.phase == .wakeListening, "A second finish is harmless")
        t.beginSpeaking()
        t.cancel(message: "Зупинено.")
        check(!t.speaking && t.wakeArmed, "Cancel stops speaking state")
        t.beginSpeaking()
        t.setMicrophone(enabled: false)
        check(!t.speaking && t.phase == .microphoneOff, "Mic-off clears speaking")
        print("VoiceStateTests: \(count) state assertions passed")
    }
}
