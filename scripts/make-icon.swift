import AppKit

// BetterConsole app icon: a dark macOS squircle "screen" with a red ERROR line and timestamp,
// faint log lines below and a red cursor. Drawn at 1024 px.
// Run `swift scripts/make-icon.swift icon-1024.png`, then resize into
// App/Assets.xcassets/AppIcon.appiconset (16–512 pt at 1x and 2x).
let size: CGFloat = 1024
let out = CommandLine.arguments[1]

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// macOS icon grid: 824 px body centred, corner radius ~185, soft drop shadow.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 185
let squircle = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.45).cgColor)
rgb(58, 58, 64).setFill()
squircle.fill()
ctx.restoreGState()

// The screen fills the whole icon (no frame).
let screen = squircle
NSGradient(colors: [rgb(30, 30, 34), rgb(12, 12, 14)])!.draw(in: screen, angle: -90)
// Faint edge highlight so the shape reads on dark backgrounds.
ctx.saveGState()
screen.addClip()
rgb(255, 255, 255, 0.14).setStroke()
screen.lineWidth = 6
screen.stroke()
ctx.restoreGState()

// Subtle red glow behind the text.
ctx.saveGState()
screen.addClip()
let glow = NSGradient(colors: [rgb(255, 59, 48, 0.22), rgb(255, 59, 48, 0)])!
glow.draw(fromCenter: NSPoint(x: 512, y: 600), radius: 0, toCenter: NSPoint(x: 512, y: 600), radius: 420, options: [])
ctx.restoreGState()

func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, at point: NSPoint, kern: CGFloat = 0, glow: Bool = false) {
    let font = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    let shadow = NSShadow()
    if glow {
        shadow.shadowColor = rgb(255, 69, 58, 0.75)
        shadow.shadowBlurRadius = 22
        shadow.shadowOffset = .zero
    }
    var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: kern]
    if glow { attrs[.shadow] = shadow }
    NSAttributedString(string: text, attributes: attrs).draw(at: point)
}

let red = rgb(255, 69, 58)
let left: CGFloat = 214

// ERROR + timestamp.
draw("ERROR", size: 168, weight: .heavy, color: red, at: NSPoint(x: left - 6, y: 560), kern: 4, glow: true)
draw("21:45", size: 112, weight: .bold, color: red.withAlphaComponent(0.85), at: NSPoint(x: left, y: 420), kern: 2, glow: true)

// Faint log lines.
let lineColor = rgb(235, 235, 245, 0.18)
for (i, w) in [420.0, 520.0, 360.0].enumerated() {
    let y = 330 - CGFloat(i) * 52
    let bar = NSBezierPath(roundedRect: NSRect(x: left, y: y, width: CGFloat(w), height: 22), xRadius: 11, yRadius: 11)
    lineColor.setFill()
    bar.fill()
}

// Red block cursor at the end of the last line.
let cursor = NSBezierPath(roundedRect: NSRect(x: left + 380, y: 226, width: 44, height: 30), xRadius: 6, yRadius: 6)
red.setFill()
cursor.fill()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
