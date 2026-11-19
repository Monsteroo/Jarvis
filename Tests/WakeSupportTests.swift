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

        // Activation must be an explicit first-word address, never a mention.
        for mention in ["Я сказав Jarvis закрий Safari", "Ну, Джарвіс, стоп.",
                        "Please ask Jarvis to open Terminal", "This is Jarvis, close Safari",
                        "Джарвісик відкрий браузер", "Jarvis2 open Terminal", "Жарвес, яка погода?",
                        "Джагрес відкрий пошту", "Відкрий браузер.", "", "— …"] {
            let result = WakeText.stripLeadingWakeWord(mention)
            check(!result.found && result.text == mention, "Non-address must not activate: \(mention)")
        }

        // WakeText: the command recording includes the keyword; strip it.
        func strip(_ t: String) -> String { WakeText.stripLeadingWakeWord(t).text }
        check(strip("Джарвіс, відкрий браузер.") == "Відкрий браузер.", "Ukrainian spelling is stripped")
        check(strip("Jarvis, відкрий браузер.") == "Відкрий браузер.", "Latin spelling is stripped")
        check(strip("Jarvis. Open terminal.") == "Open terminal.", "Sentence break after the keyword")
        check(strip("Jarvis Open Terminal") == "Open Terminal", "No punctuation after the keyword")
        check(WakeText.stripPrerollWakeWord("Жарвес, яка погода?").text == "Яка погода?", "Misheard spelling Жарвес")
        check(WakeText.stripPrerollWakeWord("Джагрес відкрий пошту").text == "Відкрий пошту", "Misheard spelling Джагрес")
        check(WakeText.stripPrerollWakeWord("Ну, Джарвіс, стоп.").text == "Стоп.", "Words before the keyword are dropped")
        check(WakeText.stripLeadingWakeWord("Джарвіс.") == ("", true), "Keyword alone leaves an empty command")
        check(WakeText.stripLeadingWakeWord("Відкрий браузер.") == ("Відкрий браузер.", false), "No keyword: text unchanged")
        check(strip("Відкрий, будь ласка, сервіс Jarvis") == "Відкрий, будь ласка, сервіс Jarvis", "Keyword after the first three words is kept")
        check(!WakeText.isWakeWord("Чарльз") && !WakeText.isWakeWord("сервіс") && !WakeText.isWakeWord("гараж"),
              "Unrelated words are not the keyword")
        check(!WakeText.isWakeWord("Харків") && !WakeText.isWakeWord("Ярослав") && !WakeText.isWakeWord("Harvard"),
              "Similar-sounding names are not the keyword")

        check(strip("  «ДЖАРВІС», відкрий Safari") == "Відкрий Safari", "Leading whitespace, quotes and case")
        check(strip("— JARVIS:open Terminal") == "Open Terminal", "Punctuation separates the exact keyword")
        check(WakeText.command(from: "Я сказав Jarvis закрий Safari", prefixConfirmed: false) == nil,
              "Raw KWS transcript cannot bypass strict activation")
        check(WakeText.command(from: "відкрий Safari", prefixConfirmed: false) == nil,
              "Missing wake word rejects unconfirmed capture")
        check(WakeText.command(from: "Jarvis, open Terminal", prefixConfirmed: false) == "Open Terminal",
              "Raw KWS transcript accepts a leading address")
        check(WakeText.command(from: "відкрий Safari", prefixConfirmed: true) == "відкрий Safari",
              "A separately confirmed wake word does not need repetition")
        check(WakeText.command(from: "Ну, Джарвіс, стоп.", prefixConfirmed: true) == "Стоп.",
              "Preroll cleanup is permitted after confirmed activation")
        check(WakeText.command(from: "Джарвіс.", prefixConfirmed: false) == "",
              "Standalone wake word requests a follow-up capture")
        var seedSegment = UtteranceSegmenter()
        let longPrefix = Array(voice(4).prefix(512 * 100))
        check(seedSegment.activationSamples == nil, "Idle KWS cannot invent a seed without a speech segment")
        _ = seedSegment.feed(longPrefix, start: 0)
        check(seedSegment.activationSamples == longPrefix, "KWS retains the whole prefix, beyond a 1.5-second lookback")
        _ = seedSegment.feed(silence(1), start: longPrefix.count)
        check(seedSegment.activationSamples == nil, "Closed speech segment cannot seed a later unrelated detection")
        seedSegment.reset()
        check(seedSegment.activationSamples == nil, "Restart clears the KWS validation seed")

        // UtteranceSegmenter: speech segments for Parakeet screening.
        var seg = UtteranceSegmenter()
        check(seg.feed(silence(3), start: 0).isEmpty, "Silence produces no segment")
        var got = seg.feed(voice(1), start: 48_000)
        check(got.isEmpty && seg.inUtterance, "Voice opens a segment without closing it")
        got = seg.feed(silence(1), start: 64_000)
        check(got.count == 1, "A pause closes the segment")
        if let u = got.first {
            check(u.samples.count >= 16_000 && u.samples.count <= 16_000 + Int(0.4 * 16_000) + 4 * 512 + Int(0.25 * 16_000) + 512,
                  "Segment = preroll + voice + short tail")
            check(u.end > 64_000 && u.end <= 64_000 + Int(0.25 * 16_000) + 512, "Segment end is absolute, just after the voice")
            check(seg.lastEnd == u.end, "Last end is remembered for de-duplication")
        }
        seg.reset()
        let twoPhrases = voice(0.8) + silence(1.0) + voice(0.8) + silence(1.0)
        check(seg.feed(twoPhrases, start: 0).count == 2, "Two phrases separated by 1 s are two segments")
        seg.reset()
        let withPause = voice(0.6) + silence(0.3) + voice(0.6) + silence(1.0)
        check(seg.feed(withPause, start: 0).count == 1, "A 0.3 s pause inside a phrase does not split it")
        seg.reset()
        check(seg.feed([Float](repeating: 0.5, count: 512 * 2) + silence(1), start: 0).isEmpty, "A click is not a segment")
        seg.reset()
        let long = seg.feed(voice(13), start: 0)
        check(long.count == 1 && long[0].samples.count <= 12 * 16_000 + 512, "Long speech is cut at 12 s")
        seg.reset()
        var chunked: [UtteranceSegmenter.Utterance] = []
        let stream = silence(0.5) + voice(1) + silence(1)
        for chunkStart in stride(from: 0, to: stream.count, by: 333) {
            chunked += seg.feed(Array(stream[chunkStart..<min(chunkStart + 333, stream.count)]), start: chunkStart)
        }
        var whole = UtteranceSegmenter()
        check(chunked == whole.feed(stream, start: 0), "Chunk boundaries do not change segments")
        _ = seg.feed(voice(0.5), start: 1_000_000)
        check(seg.feed(silence(1), start: 5_000_000).isEmpty && !seg.inUtterance, "A gap in sample indices starts over")
        print("WakeSupportTests: \(count) assertions passed")
    }
}
