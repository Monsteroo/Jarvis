import Foundation

@main
struct AudioMetricsTests {
    static func main() {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            assert(condition(), message)
            count += 1
        }
        let analyzer = AudioAnalyzer()
        let n = AudioAnalyzer.windowSize
        func sine(_ hz: Float, _ amplitude: Float) -> [Float] {
            (0..<n).map { amplitude * sin(2 * .pi * hz * Float($0) / 16_000) }
        }

        let silence = analyzer.analyze([Float](repeating: 0, count: n))
        check(silence.rms == 0 && silence.peak == 0, "Digital silence is zero")
        check(silence.bands.allSatisfy { $0 == 0 }, "Silence draws no bands")

        let hiss = analyzer.analyze((0..<n).map { _ in Float.random(in: -0.0005...0.0005) })
        check(hiss.rms == 0, "Quiet room noise stays below the visual gate")
        // Measured built-in-mic room noise on the target Mac: ≈ −47 dBFS RMS.
        let room = analyzer.analyze((0..<n).map { _ in Float.random(in: -0.0078...0.0078) })
        check(room.rms == 0 && room.bands.allSatisfy { $0 == 0 }, "Measured room noise does not look like speech")

        let nan = analyzer.analyze([Float](repeating: .nan, count: n))
        check(nan.rms == 0 && nan.bands.allSatisfy { $0.isFinite }, "NaN input is sanitised")
        let inf = analyzer.analyze([Float](repeating: .infinity, count: n))
        check(inf.rms.isFinite && inf.peak.isFinite, "Infinity input is sanitised")

        let short = analyzer.analyze([0.2, -0.2, 0.2])
        check(short.rms.isFinite, "Short window does not crash")
        check(analyzer.analyze([]).rms == 0, "Empty window is silent")

        let speechLike = analyzer.analyze(sine(250, 0.3))
        check(speechLike.rms > 0.5, "Loud voice-range tone produces a strong envelope")
        let low = speechLike.bands.firstIndex(of: speechLike.bands.max()!)!
        let high = analyzer.analyze(sine(4_000, 0.3))
        let highBand = high.bands.firstIndex(of: high.bands.max()!)!
        check(low < highBand, "Bands follow frequency: 250 Hz below 4 kHz")
        let quiet = analyzer.analyze(sine(250, 0.01))
        check(quiet.rms < speechLike.rms, "Envelope follows amplitude")
        check(speechLike.bands.allSatisfy { (0...1).contains($0) }, "Bands are normalised")

        var smoother = EnvelopeSmoother()
        var level = smoother.step(rms: 1, peak: 1, bands: [1, 1, 1, 1, 1, 1])
        check(level.envelope > 0.4, "Fast attack")
        for _ in 0..<80 { level = smoother.step(rms: 0, peak: 0, bands: []) }
        check(level.envelope == 0 && level.bands.allSatisfy { $0 == 0 }, "Release settles exactly to zero")
        _ = smoother.step(rms: .nan, peak: .nan, bands: [.nan])
        check(smoother.value.isFinite, "Smoother ignores NaN")
        _ = smoother.step(rms: 1, peak: 1, bands: [])
        smoother.reset()
        check(smoother.value == 0, "Reset returns to zero")

        // Pump: bounded delivery, stop publishes silence, stale capture ignored.
        var delivered: [AudioLevel] = []
        let pump = AudioMeterPump { delivered.append($0) }
        let loud = sine(300, 0.4)
        var generation = 7
        let lock = NSLock()
        pump.start(hz: 60) { lock.lock(); defer { lock.unlock() }; return (generation, loud) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        check(delivered.contains { $0.envelope > 0.3 }, "Real samples reach the UI")
        check(delivered.count <= 30, "Delivery is bounded by the tick rate")
        lock.lock(); generation = 8; lock.unlock()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        check(delivered.last!.envelope < 0.05, "A different capture generation cannot drive this session")
        pump.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        check(delivered.last == .silent, "Stop publishes silence")
        let after = delivered.count
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        check(delivered.count == after, "No ticks after stop")

        pump.start(hz: 60) { nil }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        check(delivered.last!.envelope == 0, "No source (stopped/limit) is silent")
        pump.stop()
        print("AudioMetricsTests: \(count) metric assertions passed")
    }
}
