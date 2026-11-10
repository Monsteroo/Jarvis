import Foundation

/// Local wake-word listener for the exact word "Jarvis" (sherpa-onnx KWS).
/// Runs only after the user explicitly enabled voice activation. It pulls
/// converted audio from the shared AudioCapture monitor ring on its own queue,
/// never on the audio callback and never on the main thread. Audio stays in RAM.
final class WakeListener {
    enum Mode: Equatable { case off, armed, command }
    enum Event: Equatable {
        /// The keyword fired and a command recording with this generation started.
        case wake(generation: Int)
        /// End-of-speech decision for the wake-started command.
        case endpoint(SpeechEndpoint.Outcome)
        /// A speech segment heard while armed, for local Parakeet screening.
        /// Dropped by the owner unless its transcript starts with the wake word.
        case utterance(samples: [Float], end: Int, epoch: Int)
    }

    /// BPE tokens of "JARVIS" in the en-2023-06-26 vocabulary, as the model
    /// itself decodes the word ("VI" is not a token there).
    static let keywords = "\u{2581}JA R V IS @JARVIS\n"
    /// Real-voice check with 8 search paths: 12/13 hits on two recordings and
    /// 0 false fires on ordinary speech (docs/research/2026-11-10-wake-real-voice.md).
    /// 0.15 keeps the synthetic set at 16/17; 0.25 drops it to 15/17.
    var threshold: Float = 0.15
    var score: Float = 1.0
    static let commandSeconds = 15
    /// The command recording starts this far before the detection so it holds
    /// the whole keyword: en-2023-06-26 fires 0.5–0.8 s after the word ends
    /// (≈1.3 s after it starts), and a later cut clipped commands spoken
    /// without a pause ("…відкрий браузер" → "Browser."). The keyword is then
    /// removed from the transcript (WakeText).
    static let commandLookback = 1.5
    /// End-of-speech detection starts here, so the keyword itself does not
    /// count as the command and a pause after "Jarvis" is still allowed.
    static let endpointLookback = 0.15

    private let queue = DispatchQueue(label: "jarvis.wake", qos: .userInitiated)
    private let lock = NSLock()
    private var mode: Mode = .off            // guarded by lock
    private var session = 0                  // guarded by lock
    private var timer: DispatchSourceTimer?  // main thread
    private weak var capture: AudioCapture?  // set on main before start
    private let onEvent: (Event) -> Void

    // Queue-only state.
    private var spotter: OpaquePointer?
    private var epoch = -1
    private var history: [Float] = []
    private var historyStart = 0
    private var needsRestart = true
    private var cooldownUntil = 0
    private var endpoint = SpeechEndpoint()
    private var segmenter = UtteranceSegmenter()
    /// A keyword hit this soon after a screened segment ended belongs to that
    /// segment (the spotter lags 0.5–0.8 s); screening handles it, not a second turn.
    static let screenedOverlap = 1.5
    /// Opt-in developer check (JARVIS_DEBUG_WAKE=1): numbers only, never audio.
    private let debug = ProcessInfo.processInfo.environment["JARVIS_DEBUG_WAKE"] == "1"
    private var debugSamples = 0
    private var debugPeak: Float = 0
    private var debugStamp = 0.0

    private func debugLog(_ text: String) {
        guard debug else { return }
        FileHandle.standardError.write(("wake " + text + "\n").data(using: .utf8)!)
    }

    init(onEvent: @escaping (Event) -> Void) { self.onEvent = onEvent }

    var isLoaded: Bool { queue.sync { spotter != nil } }

    func load(modelDir: String, completion: @escaping (Bool) -> Void) {
        let threshold = self.threshold, score = self.score
        queue.async {
            if self.spotter == nil {
                self.spotter = WakeListener.keywords.withCString { keywords in
                    modelDir.withCString { jw_create($0, keywords, threshold, score, 1, 1) }
                }
            }
            let ok = self.spotter != nil
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// Starts pulling audio every 30 ms. Main thread.
    func start(capture: AudioCapture) {
        precondition(Thread.isMainThread)
        stop()
        self.capture = capture
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(30), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    /// Stops the listener; late ticks are ignored. Main thread.
    func stop() {
        timer?.cancel()
        timer = nil
        setMode(.off)
    }

    /// `.armed` is only entered from `.off`, so a detection that already
    /// switched to `.command` is never overwritten by a late re-arm.
    func setMode(_ newMode: Mode) {
        lock.lock()
        defer { lock.unlock() }
        if newMode == .armed && mode != .off { return }
        if newMode != mode { session += 1 }
        mode = newMode
        if newMode == .armed { queue.async { self.needsRestart = true; self.segmenter.reset() } }
    }

    var currentMode: Mode { lock.lock(); defer { lock.unlock() }; return mode }

    func close() {
        queue.async {
            if let spotter = self.spotter { jw_free(spotter) }
            self.spotter = nil
        }
    }

    // MARK: Queue

    private func tick() {
        guard let capture, let chunk = capture.drainMonitor() else { return }
        if chunk.epoch != epoch {
            epoch = chunk.epoch
            history.removeAll(keepingCapacity: true)
            historyStart = chunk.start
            needsRestart = true
            // Sample indices restart with the monitor; a cooldown from the old
            // time base would silently swallow detections (seen live: a hit
            // ignored after re-enabling wake).
            cooldownUntil = 0
            segmenter.reset()
        }
        history.append(contentsOf: chunk.samples)
        let keep = 16_000 * 3
        if history.count > keep {
            let drop = history.count - keep
            history.removeFirst(drop)
            historyStart += drop
        }
        guard !chunk.samples.isEmpty else { return }

        lock.lock()
        let mode = self.mode
        let ticket = session
        lock.unlock()

        if debug {
            debugSamples += chunk.samples.count
            debugPeak = max(debugPeak, SpeechEndpoint.level(chunk.samples[...]))
            let now = ProcessInfo.processInfo.systemUptime
            if now - debugStamp >= 2 {
                debugStamp = now
                debugLog("mode=\(mode) samples=\(debugSamples) peakLevel=\(String(format: "%.2f", debugPeak)) loaded=\(spotter != nil)")
                debugSamples = 0
                debugPeak = 0
            }
        }

        switch mode {
        case .off:
            return
        case .command:
            let outcome = endpoint.feed(chunk.samples)
            guard outcome != .listening else { return }
            debugLog("endpoint=\(outcome) heardSpeech=\(endpoint.heardSpeech)")
            lock.lock()
            let current = self.mode == .command && session == ticket
            if current { self.mode = .off; session += 1 }
            lock.unlock()
            if current { DispatchQueue.main.async { self.onEvent(.endpoint(outcome)) } }
        case .armed:
            guard let spotter else { return }
            if needsRestart {
                jw_restart(spotter)
                needsRestart = false
            }
            let epochNow = epoch
            for utterance in segmenter.feed(chunk.samples, start: chunk.start) {
                debugLog(String(format: "utterance %.2f s", Double(utterance.samples.count) / 16_000))
                DispatchQueue.main.async {
                    self.onEvent(.utterance(samples: utterance.samples, end: utterance.end, epoch: epochNow))
                }
            }
            var unused: Float = 0
            let fired = chunk.samples.withUnsafeBufferPointer {
                jw_accept(spotter, $0.baseAddress, Int32($0.count), &unused)
            }
            guard fired == 1 else { return }
            let drainedEnd = chunk.start + chunk.samples.count
            debugLog("fired at=\(drainedEnd) cooldown=\(drainedEnd < cooldownUntil)")
            guard drainedEnd >= cooldownUntil else { return }
            if !segmenter.inUtterance, let last = segmenter.lastEnd,
               drainedEnd - last < Int(Self.screenedOverlap * 16_000) {
                debugLog("fired inside a screened segment; left to screening")
                return
            }
            cooldownUntil = drainedEnd + 16_000 * 2
            let cut = max(historyStart, drainedEnd - Int(Self.commandLookback * 16_000))
            let seed = cut < drainedEnd ? Array(history[(cut - historyStart)...]) : []
            lock.lock()
            guard self.mode == .armed, session == ticket else { lock.unlock(); return }
            let generation = capture.beginRecording(seed: seed, maximumSeconds: Self.commandSeconds)
            if generation != nil {
                self.mode = .command
                session += 1
                endpoint.reset()
                _ = endpoint.feed(Array(seed.suffix(Int(Self.endpointLookback * 16_000))))
            }
            lock.unlock()
            needsRestart = true
            segmenter.reset()
            if let generation { DispatchQueue.main.async { self.onEvent(.wake(generation: generation)) } }
        }
    }

    /// Screening heard the wake word alone: record the next phrase as the
    /// command, starting from the end of that segment so nothing said during
    /// screening is lost. Main thread.
    func startCommand(after end: Int, epoch expected: Int) {
        queue.async {
            guard let capture = self.capture, expected == self.epoch else { return }
            let historyEnd = self.historyStart + self.history.count
            let from = min(max(end, self.historyStart), historyEnd)
            let seed = Array(self.history[(from - self.historyStart)...])
            self.lock.lock()
            guard self.mode == .armed else { self.lock.unlock(); return }
            let generation = capture.beginRecording(seed: seed, maximumSeconds: Self.commandSeconds)
            var outcome = SpeechEndpoint.Outcome.listening
            if generation != nil {
                self.mode = .command
                self.session += 1
                self.endpoint.reset()
                outcome = self.endpoint.feed(seed)
                if outcome != .listening { self.mode = .off; self.session += 1 }
            }
            self.lock.unlock()
            self.needsRestart = true
            self.segmenter.reset()
            self.debugLog(String(format: "command after screened keyword, seed %.2f s", Double(seed.count) / 16_000))
            guard let generation else { return }
            DispatchQueue.main.async {
                self.onEvent(.wake(generation: generation))
                if outcome != .listening { self.onEvent(.endpoint(outcome)) }
            }
        }
    }
}
