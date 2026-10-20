// Draws the Notas app icon and writes Resources/AppIcon.icns (plus a 1024px PNG preview).
// Usage: swift scripts/make-icon.swift   (run from the repo root)
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources")

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

/// Draws the icon into a square bitmap of `pixels` size.
func render(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gc
    let ctx = gc.cgContext
    let s = CGFloat(pixels) / 1024
    ctx.scaleBy(x: s, y: s)

    // macOS icon grid: 824pt squircle centered on a 1024 canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)

    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    hex(0x15131C).setFill()
    shape.fill()
    ctx.restoreGState()

    // Background gradient: deep violet ink.
    ctx.saveGState()
    shape.addClip()
    let bg = NSGradient(colors: [hex(0x2E2758), hex(0x17151F), hex(0x0E0D12)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    bg.draw(in: tile, angle: -60)

    // Soft glow behind the letter.
    let glow = NSGradient(colors: [hex(0x8B7CFF, 0.2), hex(0x8B7CFF, 0)])!
    glow.draw(fromCenter: CGPoint(x: 470, y: 560), radius: 0, toCenter: CGPoint(x: 470, y: 560), radius: 420, options: [])

    // A few faint ruled lines, like a page.
    hex(0xFFFFFF, 0.045).setFill()
    for i in 0..<5 {
        NSBezierPath(rect: CGRect(x: 230, y: 268 + CGFloat(i) * 62, width: 564, height: 3)).fill()
    }
    ctx.restoreGState()

    // Inner highlight on the top edge.
    ctx.saveGState()
    shape.addClip()
    let rim = NSBezierPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), xRadius: 185, yRadius: 185)
    rim.lineWidth = 3
    NSGradient(colors: [hex(0xFFFFFF, 0.22), hex(0xFFFFFF, 0)])!.draw(in: rim, angle: -90)
    hex(0xFFFFFF, 0.10).setStroke()
    rim.stroke()
    ctx.restoreGState()

    // The letter: New York, semibold.
    let base = NSFont.systemFont(ofSize: 600, weight: .semibold)
    let serif = NSFont(descriptor: base.fontDescriptor.withDesign(.serif)!, size: 600) ?? base
    let letter = NSAttributedString(string: "N", attributes: [
        .font: serif,
        .foregroundColor: hex(0xF6F4FB),
        .kern: -10,
    ])
    let size = letter.size()
    let origin = CGPoint(x: 512 - size.width / 2 - 34, y: 512 - size.height / 2 + 6)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    letter.draw(at: origin)
    ctx.restoreGState()

    // The accent dot, like a full stop.
    let dot = CGRect(x: origin.x + size.width - 4, y: origin.y + 128, width: 92, height: 92)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 30, color: hex(0x8B7CFF, 0.8).cgColor)
    NSGradient(colors: [hex(0xA99DFF), hex(0x7A69F5)])!.draw(in: NSBezierPath(ovalIn: dot), angle: -70)
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let png = render(pixels: points * scale).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}
try render(pixels: 1024).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("design/icon-preview.png"))

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
