import AVFoundation
import Foundation

/// Permission resolution never starts a session; only a fresh key press can.
struct CaptureGate {
    private(set) var held = false
    private(set) var recording = false

    mutating func press(enabled: Bool, authorized: Bool, ready: Bool) -> Bool {
        guard !held else { return false }
        held = true
        guard enabled && authorized && ready else { return false }
        recording = true
        return true
    }

    mutating func release() -> Bool {
        held = false
        let wasRecording = recording
        recording = false
        return wasRecording
    }

    mutating func cancel() {
        // Keep held until the physical release: repeats cannot restart capture.
        recording = false
    }
}

enum CaptureError: LocalizedError {
    case noInput, conversion, deviceChanged
    var errorDescription: String? {
        switch self {
        case .deviceChanged: return "Пристрій вводу змінився. Запис зупинено — натисніть ⌃⌥Пробіл ще раз."
        case .noInput: return "Мікрофон недоступний. Перевірте пристрій вводу."
        case .conversion: return "Не вдалося перетворити звук із мікрофона."
        }
    }
}


/// One microphone engine shared by PTT recording and, when the user enabled
/// it, wake-word monitoring. The engine runs only while one of them needs it.
/// No audio is written to disk.
final class AudioCapture {
    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var recording = false
    private var monitoring = false
    /// Mirrors `engine != nil` under the lock, for callers off the main thread.
    private var engineRunning = false
    /// Changes on every recording start/stop: stale limit callbacks are ignored.
    private var generation = 0
    /// Changes on every engine start/stop: stale failure callbacks are ignored.
    private var engineGeneration = 0
    private var samples: [Float] = []
    private var maximumSamples = 16_000 * 30
    /// Copy of the newest converted 16 kHz samples for level metering only.
    /// Fixed size and preallocated: the tap does a bounded memcpy, no analysis.
    private var meterWindow = [Float](repeating: 0, count: AudioAnalyzer.windowSize)
    private var meterFilled = 0
    /// Last 3 s of converted audio for the wake listener (RAM only).
    private var monitorRing = SampleRing(capacity: 16_000 * 3)
    private var monitorEpoch = 0
    private var configObserver: NSObjectProtocol?
    var onLimit: (() -> Void)?
    var onFailure: ((Error) -> Void)?

    var isRunning: Bool { engine != nil }
    var isMonitoring: Bool { lock.lock(); defer { lock.unlock() }; return monitoring }

    // MARK: Engine

    private func startEngine() throws {
        precondition(Thread.isMainThread)
        guard engine == nil else { return }
        let newEngine = AVAudioEngine()
        let input = newEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                  sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw CaptureError.noInput
        }
        lock.lock()
        engineGeneration += 1
        let engineTicket = engineGeneration
        monitorRing.reset()
        monitorEpoch += 1
        lock.unlock()
        input.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock()
            guard self.recording || self.monitoring else { self.lock.unlock(); return }
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16_000 / inputFormat.sampleRate) + 64)
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                self.lock.unlock()
                return
            }
            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                if supplied { inputStatus.pointee = .noDataNow; return nil }
                supplied = true
                inputStatus.pointee = .haveData
                return buffer
            }
            if status == .error {
                self.recording = false
                self.monitoring = false
                self.lock.unlock()
                DispatchQueue.main.async {
                    self.lock.lock()
                    let current = engineTicket == self.engineGeneration
                    self.lock.unlock()
                    if current { self.onFailure?(conversionError ?? CaptureError.conversion as NSError) }
                }
                return
            }
            var reachedLimit = false
            let ticket = self.generation
            if let channel = output.floatChannelData?[0] {
                let frames = Int(output.frameLength)
                if self.recording {
                    let count = min(frames, self.maximumSamples - self.samples.count)
                    if count > 0 { self.samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count)) }
                    self.pushMeter(channel, count: frames)
                    reachedLimit = self.samples.count >= self.maximumSamples
                    if reachedLimit { self.recording = false }
                }
                if self.monitoring { self.monitorRing.write(channel, count: frames) }
            }
            self.lock.unlock()
            if reachedLimit {
                DispatchQueue.main.async {
                    self.lock.lock()
                    let current = ticket == self.generation
                    self.lock.unlock()
                    if current { self.onLimit?() }
                }
            }
        }
        engine = newEngine
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                object: newEngine, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            let current = engineTicket == self.engineGeneration && (self.recording || self.monitoring)
            self.lock.unlock()
            if current { self.onFailure?(CaptureError.deviceChanged) }
        }
        do {
            newEngine.prepare()
            try newEngine.start()
            lock.lock()
            engineRunning = true
            lock.unlock()
        } catch {
            teardownEngine()
            throw error
        }
    }

    private func teardownEngine() {
        precondition(Thread.isMainThread)
        lock.lock()
        engineGeneration += 1
        engineRunning = false
        recording = false
        monitoring = false
        monitorRing.reset()
        lock.unlock()
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            engine.reset()
        }
        engine = nil
    }

    // MARK: Wake monitoring

    /// Keeps the engine running and feeds the monitor ring. Main thread.
    func startMonitoring() throws {
        try startEngine()
        lock.lock()
        if !monitoring { monitorRing.reset(); monitorEpoch += 1 }
        monitoring = true
        lock.unlock()
    }

    /// Stops feeding the wake listener; closes the microphone unless a
    /// recording still needs it. Main thread.
    func stopMonitoring() {
        precondition(Thread.isMainThread)
        lock.lock()
        monitoring = false
        monitorRing.reset()
        let stillRecording = recording
        lock.unlock()
        if !stillRecording { teardownEngine() }
    }

    /// Thread-safe. Unread monitor audio with its absolute start index and the
    /// epoch, which changes whenever the time base restarts.
    func drainMonitor(max limit: Int = 16_000) -> (epoch: Int, start: Int, samples: [Float])? {
        lock.lock()
        defer { lock.unlock() }
        guard monitoring else { return nil }
        let chunk = monitorRing.drain(max: limit)
        return (monitorEpoch, chunk.start, chunk.samples)
    }

    // MARK: Recording

    /// PTT: starts the engine when needed and records from now. Main thread.
    func start(maximumSeconds: Int = 30) throws {
        try startEngine()
        guard beginRecording(seed: [], maximumSeconds: maximumSeconds, includeUnreadMonitor: false) != nil else {
            if !isMonitoring { teardownEngine() }
            throw CaptureError.noInput
        }
    }

    /// Thread-safe. Starts a recording on the running engine. `seed` is audio
    /// the caller already holds (the words right after the wake word); the
    /// not-yet-drained monitor audio is appended atomically so no sample is
    /// lost or duplicated between detection and recording. Returns the
    /// recording generation, or nil when the engine is not running or a
    /// recording is already active.
    @discardableResult
    func beginRecording(seed: [Float], maximumSeconds: Int, includeUnreadMonitor: Bool = true) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard !recording, engineRunning else { return nil }
        maximumSamples = 16_000 * max(1, min(30, maximumSeconds))
        samples = []
        samples.reserveCapacity(maximumSamples)
        samples.append(contentsOf: seed.prefix(maximumSamples))
        if includeUnreadMonitor && monitoring {
            let unread = monitorRing.peekUnread()
            samples.append(contentsOf: unread.prefix(maximumSamples - samples.count))
        }
        for i in 0..<meterWindow.count { meterWindow[i] = 0 }
        meterFilled = 0
        generation += 1
        recording = true
        return generation
    }

    var recordingGeneration: Int? {
        lock.lock(); defer { lock.unlock() }
        return recording ? generation : nil
    }

    /// Ends the current recording and returns its samples. Closes the
    /// microphone unless wake monitoring still needs it. Main thread.
    @discardableResult func stop() -> [Float] {
        precondition(Thread.isMainThread)
        lock.lock()
        recording = false
        generation += 1
        let result = samples
        samples = []
        meterFilled = 0
        let keep = monitoring
        lock.unlock()
        if !keep { teardownEngine() }
        return result
    }

    /// Mic-off and quit: closes everything. Main thread.
    func shutdown() {
        lock.lock()
        generation += 1
        samples = []
        meterFilled = 0
        lock.unlock()
        teardownEngine()
    }

    // MARK: Metering

    /// Called with `lock` held from the tap. Does not touch `samples`.
    private func pushMeter(_ source: UnsafePointer<Float>, count: Int) {
        let n = meterWindow.count
        guard count > 0 else { return }
        meterWindow.withUnsafeMutableBufferPointer { window in
            if count >= n {
                window.baseAddress!.update(from: source + (count - n), count: n)
            } else {
                window.baseAddress!.update(from: window.baseAddress! + count, count: n - count)
                (window.baseAddress! + (n - count)).update(from: source, count: count)
            }
        }
        meterFilled = min(n, meterFilled + count)
    }

    /// Thread-safe. Nil when no recording is active, so wake monitoring, a
    /// stopped or a cancelled session can never feed the visualizer.
    func meterSnapshot() -> (generation: Int, window: [Float])? {
        lock.lock()
        defer { lock.unlock() }
        guard recording, meterFilled > 0 else { return nil }
        return (generation, meterWindow)
    }
}
