import Foundation
import AVFoundation

@main struct DiagnosticTests {
 static func main() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-diagnostic-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = DiagnosticCapture()
    let samples: [Float] = (0..<16000).map { Float(sin(Double($0) * 0.05)) * 0.3 }
    assert(!recorder.armed)
    assert((try? recorder.finish(samples: samples, directory: directory)) == nil)
    assert(!FileManager.default.fileExists(atPath: directory.path))
    recorder.arm()
    recorder.cancel()
    assert((try? recorder.finish(samples: samples, directory: directory)) == nil)
    recorder.arm()
    let url = try recorder.finish(samples: samples, directory: directory)
    assert(url != nil && !recorder.armed)
    assert((try? recorder.finish(samples: samples, directory: directory)) == nil)
    let file = try AVAudioFile(forReading: url!)
    assert(file.length == 16000 && file.processingFormat.sampleRate == 16000)
    assert(file.processingFormat.channelCount == 1)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16000)!
    try file.read(into: buffer)
    assert(abs(buffer.floatChannelData![0][100] - samples[100]) < 0.000001)
    let attrs = try FileManager.default.attributesOfItem(atPath: url!.path)
    assert((attrs[.posixPermissions] as! NSNumber).intValue == 0o600)
    recorder.arm()
    do {
      _ = try recorder.finish(samples: [.nan], directory: directory)
      assertionFailure("Invalid audio must be rejected")
    } catch {}
    assert(!recorder.armed)
    let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    assert(files.count == 1)
    print("DiagnosticTests: one-shot, cancellation, WAV round-trip, private permissions passed")
 }
}
