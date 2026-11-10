import AVFoundation

/// Short, quiet two-tone cue played when "Jarvis" is recognised.
/// Synthesised in memory: no audio file is bundled and nothing is recorded.
final class AcknowledgmentSound {
    static let sampleRate = 44_100
    static let duration = 0.16

    /// Two soft high tones (G6 → C7) with sin² envelopes, so there are no
    /// clicks and little energy in the main speech band.
    static func samples(sampleRate: Int = sampleRate) -> [Float] {
        let rate = Double(sampleRate)
        let total = Int(duration * rate)
        var out = [Float](repeating: 0, count: total)
        for (frequency, start, length) in [(1568.0, 0.0, 0.075), (2093.0, 0.065, 0.095)] {
            let first = Int(start * rate), count = Int(length * rate)
            for i in 0..<count where first + i < total {
                let shape = sin(Double.pi * Double(i) / Double(count))
                out[first + i] += Float(0.45 * shape * shape * sin(2 * Double.pi * frequency * Double(i) / rate))
            }
        }
        return out
    }

    /// 16-bit mono PCM WAV in memory.
    static func wavData(_ samples: [Float], sampleRate: Int = sampleRate) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let payload = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + payload))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(payload))
        for sample in samples { append(Int16(max(-1, min(1, sample)) * Float(Int16.max))) }
        return data
    }

    private lazy var player: AVAudioPlayer? = {
        let player = try? AVAudioPlayer(data: Self.wavData(Self.samples()))
        player?.prepareToPlay()
        return player
    }()

    var volume: Float = 0.35

    func play() {
        guard let player else { return }
        player.stop()
        player.currentTime = 0
        player.volume = volume
        player.play()
    }
}
