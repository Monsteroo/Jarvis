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
    }

    /// BPE tokens of "JARVIS" from the model's own bpe.model (sentencepiece).
    static let keywords = "\u{2581}JA R VI S @JARVIS\n"
    /// Starting point from the synthetic fixture sweep; tune on real voices.
    var threshold: Float = 0.15
    var score: Float = 1.0
    static let commandSeconds = 15
    static let detectionLag = 0.15

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
        if newMode == .armed { queue.async { self.needsRestart = true } }
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
            var unused: Float = 0
            let fired = chunk.samples.withUnsafeBufferPointer {
                jw_accept(spotter, $0.baseAddress, Int32($0.count), &unused)
            }
            guard fired == 1 else { return }
            let drainedEnd = chunk.start + chunk.samples.count
            debugLog("fired at=\(drainedEnd)")
            guard drainedEnd >= cooldownUntil else { return }
            cooldownUntil = drainedEnd + 16_000 * 2
            // Detection lands 0.32–0.52 s after the spoken word ends (measured
            // on fixtures). Live test: starting 0.30 s back left the "s" of
            // "Jarvis" in the command, so start 0.15 s back.
            let cut = max(historyStart, drainedEnd - Int(Self.detectionLag * 16_000))
            let seed = cut < drainedEnd ? Array(history[(cut - historyStart)...]) : []
            lock.lock()
            guard self.mode == .armed, session == ticket else { lock.unlock(); return }
            let generation = capture.beginRecording(seed: seed, maximumSeconds: Self.commandSeconds)
            if generation != nil {
                self.mode = .command
                session += 1
                endpoint.reset()
                _ = endpoint.feed(seed)
            }
            lock.unlock()
            needsRestart = true
            if let generation { DispatchQueue.main.async { self.onEvent(.wake(generation: generation)) } }
        }
    }
}
