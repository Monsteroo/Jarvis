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
    case noInput, conversion
    var errorDescription: String? {
        switch self {
        case .noInput: return "Мікрофон недоступний. Перевірте пристрій вводу."
        case .conversion: return "Не вдалося перетворити звук із мікрофона."
        }
    }
}

/// The engine exists only during a key-held session. No audio is written to disk.
final class AudioCapture {
    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var active = false
    private var generation = 0
    private var samples: [Float] = []
    private var maximumSamples = 16_000 * 30
    var onLimit: (() -> Void)?
    var onFailure: ((Error) -> Void)?

    func start(maximumSeconds: Int = 30) throws {
        precondition(Thread.isMainThread)
        guard engine == nil else { return }
        maximumSamples = 16_000 * max(1,min(30,maximumSeconds))
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
        samples = []
        samples.reserveCapacity(maximumSamples)
        active = true
        generation += 1
        let ticket = generation
        lock.unlock()
        input.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock()
            guard self.active else { self.lock.unlock(); return }
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
                self.active = false
                self.lock.unlock()
                DispatchQueue.main.async {
                    self.lock.lock()
                    let current = ticket == self.generation
                    self.lock.unlock()
                    if current { self.onFailure?(conversionError ?? CaptureError.conversion as NSError) }
                }
                return
            }
            if let channel = output.floatChannelData?[0] {
                let count = min(Int(output.frameLength), self.maximumSamples - self.samples.count)
                if count > 0 { self.samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count)) }
            }
            let reachedLimit = self.samples.count >= self.maximumSamples
            if reachedLimit { self.active = false }
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
        do {
            newEngine.prepare()
            try newEngine.start()
        } catch {
            _ = stop()
            throw error
        }
    }

    @discardableResult func stop() -> [Float] {
        precondition(Thread.isMainThread)
        lock.lock()
        active = false
        generation += 1
        let result = samples
        samples = []
        lock.unlock()
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            engine.reset()
        }
        engine = nil
        return result
    }
}
