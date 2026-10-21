// Renders the app icon into an .iconset directory: swift make_icon.swift <out.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024

    // Squircle on the standard macOS icon grid.
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = CGPath(roundedRect: body, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [
        NSColor(srgbRed: 0.72, green: 0.90, blue: 0.42, alpha: 1).cgColor,
        NSColor(srgbRed: 0.30, green: 0.60, blue: 0.18, alpha: 1).cgColor,
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])

    // Soft top sheen.
    let sheen = [NSColor.white.withAlphaComponent(0.28).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray
    let sheenGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: sheen, locations: [0, 1])!
    ctx.drawLinearGradient(sheenGradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY), options: [])

    // Waveform bars.
    let heights: [CGFloat] = [0.22, 0.42, 0.68, 0.46, 0.84, 0.56, 0.34, 0.6, 0.28]
    let barWidth = 46 * s
    let gap = 30 * s
    let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = body.midX - totalWidth / 2
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.95).cgColor)
    for h in heights {
        let height = h * 520 * s
        let bar = CGRect(x: x, y: body.midY - height / 2, width: barWidth, height: height)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        x += barWidth + gap
    }
    ctx.fillPath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: output.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: output.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
