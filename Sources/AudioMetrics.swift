import Accelerate
import Foundation

/// One UI-facing snapshot of microphone energy. Values are 0…1 and finite.
struct AudioLevel: Equatable {
    static let bandCount = 6
    static let silent = AudioLevel(rms: 0, peak: 0, envelope: 0, bands: Array(repeating: 0, count: bandCount))
    var rms: Float
    var peak: Float
    var envelope: Float
    var bands: [Float]
}

/// Pure analysis of a 16 kHz mono window. Runs on the metrics queue, never on
/// the audio tap or the main thread.
final class AudioAnalyzer {
    static let windowSize = 512
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let hann: [Float]
    private let edges: [Int]
    private var real = [Float](repeating: 0, count: AudioAnalyzer.windowSize / 2)
    private var imag = [Float](repeating: 0, count: AudioAnalyzer.windowSize / 2)

    init() {
        let n = AudioAnalyzer.windowSize
        fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(n))), radix: .radix2, ofType: DSPSplitComplex.self)!
        hann = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        // Log-spaced speech bands, 90 Hz … 7 kHz, as FFT bin indices (31.25 Hz/bin).
        let low = 90.0, high = 7_000.0
        edges = (0...AudioLevel.bandCount).map { i in
            let hz = low * pow(high / low, Double(i) / Double(AudioLevel.bandCount))
            return max(1, min(n / 2 - 1, Int(hz / (16_000.0 / Double(n)))))
        }
    }

    /// dBFS → 0…1 with a floor that keeps quiet rooms visually still.
    /// Calibrated on the M1 built-in mic: room noise ≈ −47 dBFS → 0,
    /// close speech −20…−5 dBFS → 0.6…1.
    static func normalize(db: Float) -> Float {
        guard db.isFinite else { return 0 }
        let value = (db + 45) / 38
        return value < 0.04 ? 0 : min(1, value)
    }

    func analyze(_ input: [Float]) -> (rms: Float, peak: Float, bands: [Float]) {
        let n = AudioAnalyzer.windowSize
        var window = [Float](repeating: 0, count: n)
        let count = min(n, input.count)
        for i in 0..<count {
            let v = input[input.count - count + i]
            window[n - count + i] = v.isFinite ? max(-1, min(1, v)) : 0
        }
        let rms = vDSP.rootMeanSquare(window)
        let peak = vDSP.maximumMagnitude(window)
        let rmsLevel = AudioAnalyzer.normalize(db: 20 * log10(max(rms, 1e-7)))
        let peakLevel = AudioAnalyzer.normalize(db: 20 * log10(max(peak, 1e-7)) - 9)
        guard rmsLevel > 0 else { return (0, peakLevel, Array(repeating: 0, count: AudioLevel.bandCount)) }

        vDSP.multiply(window, hann, result: &window)
        var magnitudes = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                window.withUnsafeBufferPointer { w in
                    w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                fft.forward(input: split, output: &split)
                vDSP.absolute(split, result: &magnitudes)
            }
        }
        // Scale so a full-scale sine reads ≈ 0 dB in its band.
        let scale = 1 / Float(n)
        var bands = [Float](repeating: 0, count: AudioLevel.bandCount)
        for b in 0..<AudioLevel.bandCount {
            let lo = edges[b], hi = max(edges[b] + 1, edges[b + 1])
            let slice = magnitudes[lo..<hi]
            let energy = (slice.max() ?? 0) * scale
            bands[b] = AudioAnalyzer.normalize(db: 20 * log10(max(energy, 1e-7)) + 6)
        }
        return (rms: rmsLevel, peak: peakLevel, bands: bands)
    }
}

/// Fast attack, slower release, so speech onsets are visible and the line
/// settles smoothly to zero after the voice stops.
struct EnvelopeSmoother {
    var attack: Float = 0.55
    var release: Float = 0.18
    private(set) var value: Float = 0
    private(set) var bands = [Float](repeating: 0, count: AudioLevel.bandCount)

    mutating func step(rms: Float, peak: Float, bands input: [Float]) -> AudioLevel {
        func mix(_ old: Float, _ new: Float) -> Float {
            let target = new.isFinite ? max(0, min(1, new)) : 0
            let k = target > old ? attack : release
            let next = old + (target - old) * k
            return next < 0.002 ? 0 : next
        }
        value = mix(value, rms)
        for i in 0..<bands.count { bands[i] = mix(bands[i], i < input.count ? input[i] : 0) }
        let cleanPeak = peak.isFinite ? max(0, min(1, peak)) : 0
        return AudioLevel(rms: rms.isFinite ? max(0, min(1, rms)) : 0, peak: cleanPeak, envelope: value, bands: bands)
    }

    mutating func reset() {
        value = 0
        bands = [Float](repeating: 0, count: AudioLevel.bandCount)
    }
}

/// Pulls the latest window from AudioCapture at a bounded rate, analyses it
/// off the main thread and delivers only the newest snapshot to the UI. At most
/// one main-thread delivery is pending at a time, so nothing queues up.
final class AudioMeterPump {
    typealias Source = () -> (generation: Int, window: [Float])?
    private let queue = DispatchQueue(label: "jarvis.audio-metrics", qos: .userInitiated)
    private let analyzer = AudioAnalyzer()
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var smoother = EnvelopeSmoother()
    private var session = 0
    private var sourceGeneration: Int?
    private var latest = AudioLevel.silent
    private var deliveryPending = false
    private let deliver: (AudioLevel) -> Void

    init(deliver: @escaping (AudioLevel) -> Void) { self.deliver = deliver }

    /// `source` must be thread-safe; it is called on the metrics queue.
    func start(hz: Double = 30, source: @escaping Source) {
        stop()
        lock.lock()
        session += 1
        let ticket = session
        lock.unlock()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1 / hz, leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in self?.tick(ticket: ticket, source: source) }
        self.timer = timer
        timer.resume()
    }

    /// Stops sampling and publishes silence; late ticks of the old session are dropped.
    func stop() {
        timer?.cancel()
        timer = nil
        lock.lock()
        session += 1
        sourceGeneration = nil
        latest = .silent
        lock.unlock()
        queue.async { self.smoother.reset() }
        schedule()
    }

    private func tick(ticket: Int, source: Source) {
        lock.lock()
        let current = ticket == session
        lock.unlock()
        guard current else { return }
        var level = AudioLevel.silent
        if let snapshot = source() {
            lock.lock()
            if sourceGeneration == nil { sourceGeneration = snapshot.generation }
            let sameCapture = sourceGeneration == snapshot.generation
            lock.unlock()
            if sameCapture {
                let result = analyzer.analyze(snapshot.window)
                level = smoother.step(rms: result.rms, peak: result.peak, bands: result.bands)
            }
        } else {
            level = smoother.step(rms: 0, peak: 0, bands: [])
        }
        lock.lock()
        guard ticket == session else { lock.unlock(); return }
        latest = level
        lock.unlock()
        schedule()
    }

    private func schedule() {
        lock.lock()
        guard !deliveryPending else { lock.unlock(); return }
        deliveryPending = true
        lock.unlock()
        DispatchQueue.main.async {
            self.lock.lock()
            self.deliveryPending = false
            let level = self.latest
            self.lock.unlock()
            self.deliver(level)
        }
    }
}
