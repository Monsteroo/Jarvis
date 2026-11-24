// Renders the Jarvis app icon (ARC Current: deep navy glass, horizontal
// luminous cyan and amber voice filaments with neural impulses) as a 1024 px PNG.
// Usage: swift make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpaceCreateDeviceRGB()
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }

// macOS icon grid: 824 px rounded square centred in 1024.
let inset: CGFloat = 100
let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Drop shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: rgb(0, 0, 0, 0.55))
ctx.addPath(shape); ctx.setFillColor(rgb(0.02, 0.05, 0.09)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape); ctx.clip()
// Deep navy glass gradient.
let bg = CGGradient(colorsSpace: space, colors: [rgb(0.035, 0.10, 0.16), rgb(0.012, 0.035, 0.065), rgb(0.02, 0.05, 0.085)] as CFArray, locations: [0, 0.6, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])
// Soft cyan bloom behind the filaments.
let bloom = CGGradient(colorsSpace: space, colors: [rgb(0.10, 0.75, 0.85, 0.30), rgb(0.10, 0.75, 0.85, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(bloom, startCenter: CGPoint(x: 512, y: 512), startRadius: 0, endCenter: CGPoint(x: 512, y: 512), endRadius: 420, options: [])

// Filaments: sums of sines with an envelope that is widest in the middle.
func filament(phase: CGFloat, amp: CGFloat, freq: CGFloat, yOffset: CGFloat) -> CGPath {
    let path = CGMutablePath()
    var first = true
    for i in stride(from: tile.minX - 20, through: tile.maxX + 20, by: 4) {
        let t = (i - tile.minX) / tile.width
        let envelope = sin(.pi * min(max(t, 0), 1))
        let y = 512 + yOffset + envelope * amp * (sin(t * freq * .pi * 2 + phase) * 0.75 + sin(t * freq * 3.1 * .pi + phase * 1.7) * 0.25)
        if first { path.move(to: CGPoint(x: i, y: y)); first = false } else { path.addLine(to: CGPoint(x: i, y: y)) }
    }
    return path
}
func stroke(_ path: CGPath, color: CGColor, width: CGFloat, glow: CGFloat) {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: glow, color: color)
    ctx.addPath(path); ctx.setStrokeColor(color); ctx.setLineWidth(width); ctx.setLineCap(.round); ctx.strokePath()
    ctx.restoreGState()
}
let cyan = rgb(0.30, 0.92, 1.0), amber = rgb(1.0, 0.68, 0.28)
// Filaments go into one transparency layer that fades out at both ends, so
// the wave seems to come from and vanish into the glass.
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
for k in 0..<14 {
    let f = CGFloat(k) - 6.5
    stroke(filament(phase: 0.9 + f * 0.11, amp: 175 - abs(f) * 7, freq: 1.15, yOffset: f * 3.5),
           color: rgb(0.30, 0.92, 1.0, 0.10 + 0.10 * (1 - abs(f) / 7)), width: 2.5, glow: 14)
}
for k in 0..<8 {
    let f = CGFloat(k) - 3.5
    stroke(filament(phase: 3.5 + f * 0.13, amp: 130 - abs(f) * 8, freq: 1.0, yOffset: f * 3),
           color: rgb(1.0, 0.68, 0.28, 0.10 + 0.12 * (1 - abs(f) / 4)), width: 2.5, glow: 12)
}
stroke(filament(phase: 3.5, amp: 130, freq: 1.0, yOffset: 0), color: amber, width: 6, glow: 28)
stroke(filament(phase: 0.9, amp: 175, freq: 1.15, yOffset: 0), color: cyan, width: 9, glow: 40)
stroke(filament(phase: 0.9, amp: 175, freq: 1.15, yOffset: 0), color: rgb(0.85, 1, 1, 0.9), width: 3, glow: 6)

// Neural impulses: small hot cores with coloured halos riding the main filaments.
func node(at x: CGFloat, phase: CGFloat, amp: CGFloat, freq: CGFloat, color: CGColor, r: CGFloat) {
    let t = (x - tile.minX) / tile.width
    let envelope = sin(.pi * t)
    let y = 512 + envelope * amp * (sin(t * freq * .pi * 2 + phase) * 0.75 + sin(t * freq * 3.1 * .pi + phase * 1.7) * 0.25)
    let halo = CGGradient(colorsSpace: space, colors: [color, color.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(halo, startCenter: CGPoint(x: x, y: y), startRadius: 0, endCenter: CGPoint(x: x, y: y), endRadius: r * 6, options: [])
    ctx.setFillColor(rgb(1, 1, 1, 1)); ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
}
for x in [290.0, 512.0, 742.0] { node(at: CGFloat(x), phase: 0.9, amp: 175, freq: 1.15, color: cyan, r: 7) }
for x in [395.0, 640.0] { node(at: CGFloat(x), phase: 3.5, amp: 130, freq: 1.0, color: amber, r: 6) }

let fade = CGGradient(colorsSpace: space, colors: [rgb(0, 0, 0, 0), rgb(0, 0, 0, 1), rgb(0, 0, 0, 1), rgb(0, 0, 0, 0)] as CFArray,
                      locations: [0.0, 0.28, 0.72, 1.0])!
ctx.setBlendMode(.destinationIn)
ctx.drawLinearGradient(fade, start: CGPoint(x: tile.minX + 20, y: 0), end: CGPoint(x: tile.maxX - 20, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.setBlendMode(.normal)
ctx.endTransparencyLayer()

// Glass rim highlight.
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(shape); ctx.setStrokeColor(rgb(0.45, 0.90, 1.0, 0.28)); ctx.setLineWidth(4); ctx.strokePath()
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
