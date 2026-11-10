import Foundation
import AVFoundation

@main struct AcknowledgmentTests {
 static func main() throws {
    var failures = 0
    func check(_ ok: Bool, _ name: String) { if !ok { failures += 1; print("FAIL: \(name)") } }

    let samples = AcknowledgmentSound.samples()
    check(samples.count == Int(AcknowledgmentSound.duration * Double(AcknowledgmentSound.sampleRate)), "duration")
    check(samples.allSatisfy { $0.isFinite && abs($0) <= 0.9 }, "bounded, never clips")
    check(samples.map(abs).max()! > 0.2, "audible")
    check(abs(samples.first!) < 0.001 && abs(samples.last!) < 0.01, "no click at start or end")
    // Quiet compared with speech: short, and most energy above 1 kHz by construction.
    let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
    check(rms < 0.25, "soft")
    check(AcknowledgmentSound.samples(sampleRate: 16_000).count == Int(AcknowledgmentSound.duration * 16_000), "other rate")

    let data = AcknowledgmentSound.wavData(samples)
    check(data.count == 44 + samples.count * 2, "wav size")
    check(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF", "riff header")
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-ack-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    try data.write(to: url)
    let file = try AVAudioFile(forReading: url)
    check(file.length == AVAudioFramePosition(samples.count), "decodes: length")
    check(file.processingFormat.sampleRate == Double(AcknowledgmentSound.sampleRate), "decodes: rate")
    check(file.processingFormat.channelCount == 1, "decodes: mono")
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count))!
    try file.read(into: buffer)
    let i = samples.count / 3
    check(abs(buffer.floatChannelData![0][i] - samples[i]) < 0.0001, "decodes: values")

    if failures > 0 { print("acknowledgment tests: \(failures) failed"); exit(1) }
    print("acknowledgment tests: 12 checks passed")
 }
}
