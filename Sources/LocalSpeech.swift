import Foundation

/// All inference and destruction run on one queue; cancellation is the only
/// concurrent bridge call and uses the bridge's atomic cancellation flag.
final class LocalSpeech {
    private let queue = DispatchQueue(label: "jarvis.inference", qos: .userInitiated)
    private let lock = NSLock()
    private var context: UnsafeMutableRawPointer?
    private var parakeet: ParakeetASR?
    private var generation = 0
    /// Separate from `generation`: cancelling an utterance must never drop a
    /// pending model-load completion, or the UI would stay in "loading" forever.
    private var loadGeneration = 0
    private var closing = false

    func load(path: String, completion: @escaping (Bool) -> Void) {
        cancel()
        lock.lock()
        loadGeneration += 1
        let ticket = loadGeneration
        lock.unlock()
        queue.async {
            self.lock.lock()
            if let previous = self.context { jv_free(previous) }
            self.context = nil
            self.parakeet = nil
            self.lock.unlock()
            let isParakeet = !path.hasSuffix(".bin")
            let parakeet = isParakeet ? try? ParakeetASR(root: URL(fileURLWithPath:path)) : nil
            let context = isParakeet ? nil : path.withCString { jv_create($0) }
            self.lock.lock()
            self.context = context
            self.parakeet = parakeet
            let closing = self.closing
            self.lock.unlock()
            DispatchQueue.main.async {
                self.lock.lock()
                let valid = ticket == self.loadGeneration && !self.closing
                self.lock.unlock()
                if !closing && valid { completion(context != nil || parakeet != nil) }
            }
        }
    }

    func transcribe(_ samples: [Float], language: String, completion: @escaping (String?, Double) -> Void) {
        lock.lock()
        let ticket = generation
        lock.unlock()
        queue.async {
            self.lock.lock()
            guard !self.closing, ticket == self.generation, self.context != nil || self.parakeet != nil else {
                self.lock.unlock()
                return
            }
            let context = self.context
            let parakeet = self.parakeet
            if let context { jv_reset_cancel(context) }
            parakeet?.resetCancellation()
            self.lock.unlock()
            let start = ProcessInfo.processInfo.systemUptime
            let text: String?
            if let parakeet {
                text = try? parakeet.transcribe(samples,language:language)
            } else if let context {
                var output = [CChar](repeating: 0, count: 65_536)
                let result = samples.withUnsafeBufferPointer { audio in
                    language.withCString { lang in
                        jv_transcribe(context, audio.baseAddress, Int32(audio.count), lang, &output, Int32(output.count))
                    }
                }
                text = result == 1 ? "" : (result == 0 ? String(cString:output).trimmingCharacters(in:.whitespacesAndNewlines) : nil)
            } else { text = nil }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            DispatchQueue.main.async {
                self.lock.lock()
                let valid = !self.closing && ticket == self.generation
                self.lock.unlock()
                if valid { completion(text, elapsed) }
            }
        }
    }

    /// Runs one throwaway Parakeet pass on a quiet synthetic tone so model
    /// weights are paged in before the first real command (a cold first pass
    /// measured 3.5–5.7 s). Silence would be skipped by the energy check, so
    /// the signal must not be silent. Queued: a real command waits behind it.
    func warmUp(completion: @escaping (Double) -> Void) {
        queue.async {
            self.lock.lock()
            let parakeet = self.closing ? nil : self.parakeet
            parakeet?.resetCancellation()
            self.lock.unlock()
            guard let parakeet else { return }
            let tone = (0..<16_000).map { Float(0.05 * sin(Double($0) * 0.07)) }
            let start = ProcessInfo.processInfo.systemUptime
            _ = try? parakeet.transcribe(tone, language: "uk")
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            DispatchQueue.main.async { completion(elapsed) }
        }
    }

    func cancel() {
        lock.lock()
        generation += 1
        if let context { jv_cancel(context) }
        parakeet?.cancel()
        lock.unlock()
    }

    /// Wake screening: transcribes one speech segment with Parakeet without
    /// touching turn generations, so it never drops or replaces a command
    /// result. Runs on the same serial queue (after any queued command).
    /// Always completes on main; nil when Parakeet is not the loaded model,
    /// on failure, or when a turn cancel interrupted it.
    func screen(_ samples: [Float], language: String, completion: @escaping (String?, Double) -> Void) {
        queue.async {
            self.lock.lock()
            let parakeet = self.closing ? nil : self.parakeet
            parakeet?.resetCancellation()
            self.lock.unlock()
            let start = ProcessInfo.processInfo.systemUptime
            let text = parakeet.flatMap { try? $0.transcribe(samples, language: language) }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            DispatchQueue.main.async { completion(text, elapsed) }
        }
    }

    func close() {
        lock.lock()
        closing = true
        generation += 1
        if let context { jv_cancel(context) }
        parakeet?.cancel()
        lock.unlock()
        queue.async {
            self.lock.lock()
            if let context = self.context { jv_free(context) }
            self.context = nil
            self.parakeet = nil
            self.lock.unlock()
        }
    }
}
