import Foundation

@main
struct WakeSupportTests {
    static func main() {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            assert(condition(), message)
            count += 1
        }

        // SampleRing
        var ring = SampleRing(capacity: 8)
        ring.write([1, 2, 3])
        check(ring.unread == 3, "Unread counts written samples")
        check(ring.peekUnread() == [1, 2, 3], "Peek does not consume")
        let first = ring.drain(max: 2)
        check(first.start == 0 && first.samples == [1, 2], "Drain returns absolute start index")
        ring.write([4, 5, 6, 7, 8, 9, 10])          // wraps around
        let second = ring.drain(max: 100)
        check(second.start == 2 && second.samples == [3, 4, 5, 6, 7, 8, 9, 10], "Wrap-around keeps order")
        check(ring.dropped == 0, "No drop while the reader keeps up")
        ring.write((11...30).map(Float.init))         // overflow: 20 samples into capacity 8
        let third = ring.drain(max: 100)
        check(third.samples == (23...30).map(Float.init), "Overflow keeps the newest samples")
        check(third.start == 22 && ring.dropped == 12, "Dropped samples are counted, indices stay absolute")
        check(ring.drain(max: 10).samples.isEmpty, "Nothing left after a full drain")
        ring.reset()
        check(ring.written == 0 && ring.unread == 0, "Reset restarts the time base")

        // SpeechEndpoint
        let n = SpeechEndpoint.frame
        func voice(_ seconds: Double) -> [Float] {
            (0..<Int(seconds * 16_000)).map { 0.2 * sin(2 * .pi * 220 * Float($0) / 16_000) }
        }
        func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * 16_000)) }

        var ep = SpeechEndpoint()
        check(ep.feed(silence(1)) == .listening, "Short silence keeps listening")
        check(ep.feed(voice(1)) == .listening, "Voice keeps listening")
        check(ep.heardSpeech, "Voice is detected")
        check(ep.feed(silence(0.4)) == .listening, "A short pause does not end the command")
        check(ep.feed(silence(0.6)) == .speechEnded, "0.8 s of silence after voice ends the command")

        ep.reset()
        check(ep.feed(silence(4.9)) == .listening, "Waits up to 5 s for a command")
        check(ep.feed(silence(0.2)) == .noSpeech, "No command after the wake word is reported")

        ep.reset()
        let click = [Float](repeating: 0.5, count: n * 2) // 64 ms burst: too short for voice
        _ = ep.feed(click)
        check(!ep.heardSpeech, "A short click is not speech")
        check(ep.feed([Float](repeating: .nan, count: n * 4)) == .listening && !ep.heardSpeech, "NaN is ignored")

        ep.reset()
        var outcome = SpeechEndpoint.Outcome.listening
        for chunk in stride(from: 0, to: 16_000 * 2, by: 300) { // odd chunk sizes like the live tap
            outcome = ep.feed(Array(voice(2)[chunk..<min(chunk + 300, 32_000)]))
        }
        check(outcome == .listening && ep.heardSpeech, "Chunk boundaries do not matter")
        let spoken = voice(1) + silence(2)
        let trimmed = SpeechEndpoint.trimTrailingSilence(spoken)
        check(trimmed.count <= 16_000 + Int(0.5 * 16_000) + n && trimmed.count >= 16_000,
              "Trailing silence is trimmed to ≈0.5 s after the voice")
        check(Array(trimmed.prefix(16_000)) == Array(spoken.prefix(16_000)), "Voice samples are untouched")
        check(SpeechEndpoint.trimTrailingSilence(silence(1)).count == 16_000, "All-silence input is left as is")
        check(SpeechEndpoint.trimTrailingSilence(voice(0.5)).count == 8_000, "No trailing silence: unchanged")
        print("WakeSupportTests: \(count) assertions passed")
    }
}
