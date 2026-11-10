import Foundation

/// Fixed-capacity sample ring with absolute indices. Writing never allocates;
/// when the reader falls behind, the oldest samples are dropped and counted.
/// Not thread-safe: the owner guards it with its own lock.
struct SampleRing {
    let capacity: Int
    private var storage: [Float]
    /// Absolute number of samples ever written since the last reset.
    private(set) var written = 0
    /// Absolute index of the next unread sample.
    private(set) var read = 0
    private(set) var dropped = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage = [Float](repeating: 0, count: self.capacity)
    }

    var unread: Int { written - read }

    mutating func reset() {
        written = 0
        read = 0
        dropped = 0
    }

    mutating func write(_ source: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        var src = source
        var n = count
        if n > capacity { // keep only the newest `capacity` samples
            src += n - capacity
            written += n - capacity
            n = capacity
        }
        storage.withUnsafeMutableBufferPointer { buffer in
            let start = written % capacity
            let first = min(n, capacity - start)
            (buffer.baseAddress! + start).update(from: src, count: first)
            if n > first { buffer.baseAddress!.update(from: src + first, count: n - first) }
        }
        written += n
        if written - read > capacity {
            dropped += written - read - capacity
            read = written - capacity
        }
    }

    mutating func write(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { if let base = $0.baseAddress { write(base, count: $0.count) } }
    }

    private func copy(from index: Int, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        guard count > 0 else { return out }
        storage.withUnsafeBufferPointer { buffer in
            out.withUnsafeMutableBufferPointer { dst in
                let start = index % capacity
                let first = min(count, capacity - start)
                dst.baseAddress!.update(from: buffer.baseAddress! + start, count: first)
                if count > first { (dst.baseAddress! + first).update(from: buffer.baseAddress!, count: count - first) }
            }
        }
        return out
    }

    /// Returns unread samples (at most `max`) with the absolute index of the first one.
    mutating func drain(max limit: Int) -> (start: Int, samples: [Float]) {
        let count = min(unread, Swift.max(0, limit))
        let start = read
        let samples = copy(from: read, count: count)
        read += count
        return (start, samples)
    }

    /// Unread samples without consuming them.
    func peekUnread() -> [Float] { copy(from: read, count: unread) }
}

/// Energy endpointing for a wake-started command. Decides when the spoken
/// command has ended, or that no command followed the wake word.
struct SpeechEndpoint {
    enum Outcome: Equatable { case listening, speechEnded, noSpeech }

    static let frame = 512                       // 32 ms at 16 kHz
    var speechLevel: Float = 0.12                // normalised level that counts as voice
    var silenceLevel: Float = 0.06               // below this counts as silence
    var startFrames = 4                          // ≈130 ms of voice to start
    var endSilenceSeconds = 0.8
    var noSpeechSeconds = 5.0

    private(set) var heardSpeech = false
    private var voiceRun = 0
    private var silenceFrames = 0
    private var frames = 0
    private var pending: [Float] = []

    mutating func reset() {
        heardSpeech = false
        voiceRun = 0
        silenceFrames = 0
        frames = 0
        pending.removeAll(keepingCapacity: true)
    }

    static func level(_ frame: ArraySlice<Float>) -> Float {
        var sum: Float = 0
        for v in frame { let x = v.isFinite ? v : 0; sum += x * x }
        let rms = (sum / Float(max(1, frame.count))).squareRoot()
        return AudioAnalyzer.normalize(db: 20 * log10(max(rms, 1e-7)))
    }

    /// Drops trailing silence after the last voiced frame, keeping `keep`
    /// seconds (0.3 s clipped a final "-нал" in a live test). Parakeet tends to
    /// invent words on long trailing silence.
    static func trimTrailingSilence(_ samples: [Float], keep: Double = 0.5, speechLevel: Float = 0.12) -> [Float] {
        var end = samples.count
        while end >= frame {
            if level(samples[(end - frame)..<end]) >= speechLevel { break }
            end -= frame
        }
        guard end >= frame else { return samples } // no voice found: leave untouched
        return Array(samples.prefix(min(samples.count, end + Int(keep * 16_000))))
    }

    mutating func feed(_ samples: [Float]) -> Outcome {
        pending.append(contentsOf: samples)
        let secondsPerFrame = Double(Self.frame) / 16_000
        var offset = 0
        defer { pending.removeFirst(offset) }
        while pending.count - offset >= Self.frame {
            let level = Self.level(pending[offset..<offset + Self.frame])
            offset += Self.frame
            frames += 1
            if level >= speechLevel {
                voiceRun += 1
                silenceFrames = 0
                if voiceRun >= startFrames { heardSpeech = true }
            } else {
                voiceRun = 0
                // Between the two levels neither counts: simple hysteresis.
                if level < silenceLevel { silenceFrames += 1 }
            }
            if heardSpeech, Double(silenceFrames) * secondsPerFrame >= endSilenceSeconds { return .speechEnded }
            if !heardSpeech, Double(frames) * secondsPerFrame >= noSpeechSeconds { return .noSpeech }
        }
        return .listening
    }
}
