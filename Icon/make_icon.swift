// Renders the Movie Audio app icon: a film strip that turns into a sound waveform.
// Usage: swift Icon/make_icon.swift <output.png>   (1024×1024)
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824pt squircle centred in a 1024 canvas.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

// Drop shadow under the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
color(0x1A1440).setFill()
squircle.fill()
ctx.restoreGState()

ctx.saveGState()
squircle.addClip()

// Background: deep indigo → night blue.
NSGradient(colors: [color(0x4B33B5), color(0x221A63), color(0x0E0C2A)],
           atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: tile, angle: -90)

// Soft glow behind the waveform.
NSGradient(colors: [color(0xFF7A59, 0.35), color(0xFF7A59, 0)])!
    .draw(fromCenter: NSPoint(x: 700, y: 512), radius: 0, toCenter: NSPoint(x: 700, y: 512), radius: 360, options: [])

// Film strip, entering from the left edge.
let strip = NSRect(x: 60, y: 362, width: 430, height: 300)
let stripPath = NSBezierPath(roundedRect: strip, xRadius: 26, yRadius: 26)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: NSColor.black.withAlphaComponent(0.45).cgColor)
color(0x15131F).setFill()
stripPath.fill()
ctx.restoreGState()

// Sprocket holes along top and bottom.
color(0xE9E6F5, 0.9).setFill()
var x: CGFloat = 92
while x + 26 < strip.maxX - 20 {
    for y in [strip.maxY - 46, strip.minY + 16] {
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 26, height: 30), xRadius: 6, yRadius: 6).fill()
    }
    x += 52
}

// Two frames with a warm "screen" glow.
for fx in [110.0, 300.0] {
    let frame = NSRect(x: fx, y: 424, width: 166, height: 176)
    let p = NSBezierPath(roundedRect: frame, xRadius: 14, yRadius: 14)
    NSGradient(colors: [color(0x7FD1FF), color(0x5A6CFF)])!.draw(in: p, angle: -60)
}

// Waveform bars flowing out of the strip.
let heights: [CGFloat] = [140, 260, 380, 300, 460, 320, 200, 110]
let barW: CGFloat = 34, gap: CGFloat = 16
let waveGradient = NSGradient(colors: [color(0xFFC857), color(0xFF6B6B), color(0xE0479E)],
                              atLocations: [0, 0.5, 1], colorSpace: .sRGB)!
for (i, h) in heights.enumerated() {
    let bx = 512 + CGFloat(i) * (barW + gap)
    let bar = NSBezierPath(roundedRect: NSRect(x: bx, y: 512 - h / 2, width: barW, height: h),
                           xRadius: barW / 2, yRadius: barW / 2)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 12, color: color(0xFF4F7A, 0.45).cgColor)
    waveGradient.draw(in: bar, angle: -90)
    ctx.restoreGState()
}

// Glassy top highlight.
NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)])!
    .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)

ctx.restoreGState()

// Hairline edge.
color(0xFFFFFF, 0.12).setStroke()
squircle.lineWidth = 2
squircle.stroke()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
