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

/// Strict first-word activation and separate cleanup for an already confirmed
/// wake turn. Fuzzy preroll cleanup must never authorize a new activation.
enum WakeText {
    static let searchWords = 3

    /// Only the first word can authorize activation: Jarvis/Джарвіс or a close
    /// ASR spelling of it (Джарвис, Жарвес, Джарвісе). A mention later in the
    /// sentence never activates. Ignore surrounding punctuation, but do not
    /// skip spoken words or digits.
    static func stripLeadingWakeWord(_ text: String) -> (text: String, found: Bool) {
        let start = text.drop(while: { $0.isWhitespace || $0.isPunctuation })
        let word = start.prefix(while: { $0.isLetter })
        guard isLeadingAddress(String(word)) else { return (text, false) }
        let rest = start.dropFirst(word.count)
        guard rest.isEmpty || rest.first!.isWhitespace || rest.first!.isPunctuation else { return (text, false) }
        let command = rest.drop(while: { $0.isWhitespace || $0.isPunctuation })
        return (command.prefix(1).uppercased() + command.dropFirst(), true)
    }

    /// nil means an unconfirmed background mention and must not be executed,
    /// displayed as an accepted command, or logged as a conversation turn.
    static func command(from text: String, prefixConfirmed: Bool) -> String? {
        if prefixConfirmed { return stripPrerollWakeWord(text).text }
        let address = stripLeadingWakeWord(text)
        return address.found ? address.text : nil
    }

    /// Tolerant cleanup only after a separate leading wake word was confirmed.
    /// It may remove preroll and ASR misspellings from the command capture.
    static func stripPrerollWakeWord(_ text: String) -> (text: String, found: Bool) {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        for index in 0..<min(searchWords, words.count) where isWakeWord(String(words[index])) {
            let rest = words[(index + 1)...].joined(separator: " ")
            let trimmed = rest.drop(while: { $0.isPunctuation || $0.isWhitespace || $0 == "—" })
            return (trimmed.prefix(1).uppercased() + trimmed.dropFirst(), true)
        }
        return (text, false)
    }

    /// First word only, for the opt-in debug trace.
    static func firstWord(_ text: String) -> String {
        String(text.drop(while: { $0.isWhitespace || $0.isPunctuation }).prefix(while: { $0.isLetter || $0.isNumber }).prefix(20))
    }

    /// First-word address check, tighter than `isWakeWord`: live run on
    /// 24 November 2026 lost 12 of 15 addresses to exact matching, because
    /// Parakeet spells the name several ways. One edit is always accepted;
    /// two only when the word starts with the J sound (Д/Дж/Ж/J), so
    /// Дарвін, Travis or Джагрес stay out.
    static func isLeadingAddress(_ word: String) -> Bool {
        let latin = transliterate(word.lowercased())
        guard (4...9).contains(latin.count), latin.allSatisfy({ $0.isLetter }) else { return false }
        let edits = distance(latin, "jarvis")
        return edits <= 1 || (edits <= 2 && latin.hasPrefix("j"))
    }

    static func isWakeWord(_ word: String) -> Bool {
        let latin = transliterate(word.lowercased().filter { $0.isLetter })
        guard (4...9).contains(latin.count), let first = latin.first, "jgdzc".contains(first) else { return false }
        return distance(latin, "jarvis") <= (latin.count >= 6 ? 3 : 2)
    }

    private static let table: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "ґ": "g", "д": "d", "е": "e", "є": "e",
        "ж": "j", "з": "z", "и": "i", "і": "i", "ї": "i", "й": "i", "к": "k", "л": "l",
        "м": "m", "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
        "ф": "f", "х": "h", "ц": "c", "ч": "ch", "ш": "sh", "щ": "sh", "ь": "", "ю": "u", "я": "a",
    ]

    static func transliterate(_ word: String) -> String {
        word.replacingOccurrences(of: "дж", with: "j").map { table[$0] ?? String($0) }.joined()
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        var row = Array(0...y.count)
        for i in 1...max(1, x.count) where !x.isEmpty {
            var previous = row[0]
            row[0] = i
            for j in 1...max(1, y.count) where !y.isEmpty {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (x[i - 1] == y[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return x.isEmpty ? y.count : row[y.count]
    }
}

/// Splits the armed microphone stream into speech segments for local Parakeet
/// screening (user decision, 10 November 2026: the English keyword spotter
/// missed most natural «Джарвіс, <команда>» phrases). Pure and allocation-bounded
/// per segment; the owner runs it on the wake queue. Audio stays in RAM.
struct UtteranceSegmenter {
    struct Utterance: Equatable {
        let samples: [Float]
        /// Absolute sample index just after the last kept sample.
        let end: Int
    }

    static let frame = 512
    var speechLevel: Float = 0.12
    var silenceLevel: Float = 0.06
    var startFrames = 4               // ≈130 ms of voice opens a segment
    var endSilenceSeconds = 0.7       // a pause this long closes it
    var prerollSeconds = 0.4          // audio kept before the detected voice onset
    var tailSeconds = 0.25            // audio kept after the last voiced frame
    var maxSeconds = 12.0             // Parakeet limit is 15 s
    var minVoicedSeconds = 0.25       // shorter bursts are not screened

    private(set) var inUtterance = false
    /// Whole current speech segment for strict KWS validation: a fixed short
    /// lookback could clip words before an incidental mention of Jarvis.
    var activationSamples: [Float]? { inUtterance ? current : nil }
    /// Absolute end of the last closed segment (emitted or not).
    private(set) var lastEnd: Int?
    private var pending: [Float] = []
    private var pendingStart = 0
    private var preroll: [Float] = []
    private var current: [Float] = []
    private var currentStart = 0
    private var voiceRun = 0
    private var voicedFrames = 0
    private var silenceFrames = 0
    private var lastVoicedEnd = 0

    private var secondsPerFrame: Double { Double(Self.frame) / 16_000 }

    mutating func reset() {
        inUtterance = false
        lastEnd = nil
        pending.removeAll(keepingCapacity: true)
        pendingStart = 0
        preroll.removeAll(keepingCapacity: true)
        current.removeAll(keepingCapacity: true)
        voiceRun = 0
        voicedFrames = 0
        silenceFrames = 0
        lastVoicedEnd = 0
    }

    /// Feeds samples whose first one has absolute index `start`. A gap in the
    /// indices (a restarted monitor) starts over.
    mutating func feed(_ samples: [Float], start: Int) -> [Utterance] {
        if pending.isEmpty && !inUtterance && preroll.isEmpty {
            pendingStart = start
        } else if start != pendingStart + pending.count {
            reset()
            pendingStart = start
        }
        pending.append(contentsOf: samples)
        var out: [Utterance] = []
        var offset = 0
        while pending.count - offset >= Self.frame {
            let frame = pending[offset..<offset + Self.frame]
            let frameStart = pendingStart + offset
            offset += Self.frame
            let level = SpeechEndpoint.level(frame)
            if !inUtterance {
                preroll.append(contentsOf: frame)
                let cap = Int(prerollSeconds * 16_000) + startFrames * Self.frame
                if preroll.count > cap { preroll.removeFirst(preroll.count - cap) }
                voiceRun = level >= speechLevel ? voiceRun + 1 : 0
                if voiceRun >= startFrames {
                    inUtterance = true
                    current = preroll
                    currentStart = frameStart + Self.frame - current.count
                    preroll.removeAll(keepingCapacity: true)
                    voicedFrames = voiceRun
                    silenceFrames = 0
                    lastVoicedEnd = current.count
                }
            } else {
                current.append(contentsOf: frame)
                if level >= speechLevel {
                    voicedFrames += 1
                    silenceFrames = 0
                    lastVoicedEnd = current.count
                } else if level < silenceLevel {
                    silenceFrames += 1
                }
                if Double(silenceFrames) * secondsPerFrame >= endSilenceSeconds {
                    close(keep: min(current.count, lastVoicedEnd + Int(tailSeconds * 16_000)), into: &out)
                } else if Double(current.count) >= maxSeconds * 16_000 {
                    close(keep: current.count, into: &out)
                }
            }
        }
        pending.removeFirst(offset)
        pendingStart += offset
        return out
    }

    private mutating func close(keep: Int, into out: inout [Utterance]) {
        let end = currentStart + keep
        if Double(voicedFrames) * secondsPerFrame >= minVoicedSeconds {
            out.append(Utterance(samples: Array(current.prefix(keep)), end: end))
        }
        lastEnd = end
        // The silence after the segment becomes preroll for the next one.
        let cap = Int(prerollSeconds * 16_000) + startFrames * Self.frame
        preroll = Array(current.suffix(min(cap, current.count - keep)))
        current.removeAll(keepingCapacity: true)
        inUtterance = false
        voiceRun = 0
        voicedFrames = 0
        silenceFrames = 0
    }
}
