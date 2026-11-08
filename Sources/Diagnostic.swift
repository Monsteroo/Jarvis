import Foundation
import AVFoundation

/// Explicit opt-in for one finished capture. Disarmed even if writing fails.
final class DiagnosticCapture {
    private(set) var armed = false
    func arm() { armed = true }
    func cancel() { armed = false }

    func finish(samples: [Float], directory: URL) throws -> URL? {
        guard armed else { return nil }
        armed = false
        guard !samples.isEmpty, samples.count <= 480_000, samples.allSatisfy({ $0.isFinite }),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("diagnostic-\(UUID().uuidString).wav")
        guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { ptr in
                buffer.floatChannelData![0].update(from: ptr.baseAddress!, count: samples.count)
            }
            // A float WAV preserves the exact samples passed to Whisper.
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        } catch {
            try? manager.removeItem(at: url)
            throw error
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}
