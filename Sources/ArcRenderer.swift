import SwiftUI

/// Visual mode of the voice filaments. Each mode has its own form, not only
/// its own colour, so the state is legible without colour.
enum FilamentMode: Equatable {
    case off        // microphone disabled: flat, grey, static
    case idle       // ready / result / error / loading: calm static wave
    case listening  // recording: amplitude and bands from the real microphone
    case thinking   // transcribing: coherent braid with travelling impulses

    init(_ phase: VoicePhase, microphoneEnabled: Bool) {
        switch phase {
        case .recording: self = .listening
        case .transcribing, .speaking: self = .thinking
        case .microphoneOff: self = .off
        default: self = microphoneEnabled ? .idle : .off
        }
    }

    var animates: Bool { self == .listening || self == .thinking }
    var frameInterval: Double { self == .listening ? 1.0 / 60 : 1.0 / 30 }
}

/// Latest smoothed microphone metrics. Kept separate from the main store so
/// 30 Hz level updates redraw only the filaments, not the whole window.
final class LevelStore: ObservableObject {
    @Published var value = AudioLevel.silent
}

enum ArcPalette {
    static let background = Color(red: 0.020, green: 0.039, blue: 0.063)
    static let backgroundTop = Color(red: 0.035, green: 0.071, blue: 0.102)
    static let cyan = Color(red: 0.204, green: 0.902, blue: 0.941)
    static let amber = Color(red: 1.0, green: 0.698, blue: 0.290)
    static let text = Color(red: 0.902, green: 0.945, blue: 0.957)
    static let secondary = Color(red: 0.580, green: 0.682, blue: 0.722)
    static let panel = Color.white.opacity(0.035)
    static let stroke = cyan.opacity(0.16)
    static let muted = Color(red: 0.42, green: 0.48, blue: 0.52)
}

struct FilamentField: View {
    @ObservedObject var level: LevelStore
    let mode: FilamentMode
    /// False when the window is hidden/occluded or Reduce Motion is on.
    let animate: Bool
    var compact = false

    var body: some View {
        let running = animate && mode.animates
        TimelineView(.animation(minimumInterval: mode.frameInterval, paused: !running)) { timeline in
            Canvas(rendersAsynchronously: false) { context, size in
                FilamentPainter.draw(&context, size: size,
                                     time: running ? timeline.date.timeIntervalSinceReferenceDate : 0,
                                     mode: mode, level: level.value, compact: compact)
            }
        }
        // Soft fade at both ends so converging strands never form a hard bright bar.
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.14),
                                     .init(color: .black, location: 0.86), .init(color: .clear, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
        .accessibilityHidden(true)
    }
}

enum FilamentPainter {
    private struct Strand {
        let offset: CGFloat     // vertical spread, -1…1
        let phase: CGFloat
        let k1: CGFloat
        let k2: CGFloat
        let speed: CGFloat
        let amber: Bool
        let band: Int
    }

    private static func strands(_ count: Int) -> [Strand] {
        (0..<count).map { i in
            let f = CGFloat(i) / CGFloat(max(1, count - 1))
            return Strand(offset: f * 2 - 1,
                          phase: CGFloat(i) * 0.83,
                          k1: 1.35 + CGFloat(i % 3) * 0.18,
                          k2: 2.6 + CGFloat(i % 4) * 0.35,
                          speed: 0.55 + CGFloat(i % 5) * 0.09,
                          amber: i % 5 == 2 || i % 7 == 5,
                          band: i % AudioLevel.bandCount)
        }
    }
    private static let full = strands(16)
    private static let small = strands(7)

    static func draw(_ context: inout GraphicsContext, size: CGSize, time: Double,
                     mode: FilamentMode, level: AudioLevel, compact: Bool) {
        let w = size.width, h = size.height
        guard w > 4, h > 4 else { return }
        let mid = h / 2
        let t = CGFloat(time.truncatingRemainder(dividingBy: 10_000))
        let env = CGFloat(level.envelope)
        let steps = compact ? 64 : 140
        let set = compact ? small : full
        context.blendMode = .plusLighter

        func y(_ s: Strand, _ u: CGFloat) -> CGFloat {
            let taper = pow(sin(.pi * u), 1.5)
            switch mode {
            case .off:
                return mid + s.offset * h * 0.035 * taper
            case .idle:
                let a = h * 0.24
                return mid + taper * (a * (0.7 * sin(u * s.k1 * 2 * .pi + s.phase)
                                            + 0.3 * sin(u * s.k2 * 2 * .pi - s.phase * 1.4))
                                      + s.offset * h * 0.09)
            case .listening:
                let band = CGFloat(level.bands[s.band])
                // Silence: near-flat lines. Voice: amplitude follows the envelope.
                let a = h * 0.46 * (0.035 + env * 0.75 + band * env * 0.35)
                let p = t * s.speed * 2.2 + s.phase
                return mid + taper * (a * (0.65 * sin(u * s.k1 * 2 * .pi + p)
                                            + 0.35 * sin(u * s.k2 * 2 * .pi - p * 1.3))
                                      + s.offset * h * (0.025 + env * 0.09))
            case .thinking:
                // One coherent braid moving left→right; strands converge.
                let p = -t * 3.2
                return mid + taper * (h * 0.15 * sin(u * 1.6 * 2 * .pi + p)
                                      + s.offset * h * 0.035 * sin(u * 3 * .pi + t * 1.7 + s.phase))
            }
        }

        for s in set {
            var path = Path()
            for i in 0...steps {
                let u = CGFloat(i) / CGFloat(steps)
                let point = CGPoint(x: u * w, y: y(s, u))
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            let color: Color
            let strength: Double
            switch mode {
            case .off: color = ArcPalette.muted; strength = 0.35
            case .idle: color = s.amber ? ArcPalette.amber : ArcPalette.cyan; strength = 0.55
            case .listening: color = s.amber ? ArcPalette.amber : ArcPalette.cyan; strength = 0.6 + Double(env) * 0.4
            case .thinking: color = s.amber ? ArcPalette.amber : ArcPalette.cyan; strength = 0.7
            }
            if mode != .off {
                context.stroke(path, with: .color(color.opacity(0.05 * strength)), lineWidth: compact ? 5 : 9)
                context.stroke(path, with: .color(color.opacity(0.12 * strength)), lineWidth: compact ? 2.2 : 3.5)
            }
            context.stroke(path, with: .color(color.opacity(0.75 * strength)), lineWidth: compact ? 0.8 : 1.0)
        }

        // Neural impulses.
        let impulses: Int
        switch mode {
        case .off: impulses = 0
        case .idle: impulses = compact ? 2 : 5
        case .listening: impulses = Int((env * (compact ? 6 : 14)).rounded())
        case .thinking: impulses = compact ? 4 : 9
        }
        guard impulses > 0 else { return }
        for k in 0..<impulses {
            let s = set[(k * 5 + 3) % set.count]
            let seed = CGFloat((k * 37) % 100) / 100
            let u: CGFloat
            switch mode {
            case .idle: u = 0.12 + seed * 0.76
            case .thinking: u = (t * 0.32 + CGFloat(k) / CGFloat(impulses)).truncatingRemainder(dividingBy: 1)
            default: u = (t * (0.12 + seed * 0.16) + seed).truncatingRemainder(dividingBy: 1)
            }
            let center = CGPoint(x: u * w, y: y(s, u))
            let fade = sin(.pi * u)
            let tint = (mode == .thinking || s.amber) ? ArcPalette.amber : ArcPalette.cyan
            let r: CGFloat = compact ? 2.2 : 3.2
            context.fill(Path(ellipseIn: CGRect(x: center.x - r * 3, y: center.y - r * 3, width: r * 6, height: r * 6)),
                         with: .color(tint.opacity(0.12 * fade)))
            context.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                         with: .color(Color.white.opacity(0.85 * fade)))
        }
    }
}
