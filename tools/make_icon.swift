// Renders MenuMySQL/AppIcon.icns.  Run from MenuMySQLMac/:  swift tools/make_icon.swift
// With a path (swift tools/make_icon.swift preview.png), writes a 512px preview there instead.
import AppKit

// MySQL's teal blue behind, going deeper.
let backTop = NSColor(red: 0.000, green: 0.459, blue: 0.561, alpha: 1)
let backBottom = NSColor(red: 0.000, green: 0.208, blue: 0.290, alpha: 1)

/// The same dolphin as the menu bar icon (StatusIcon.swift), in its 18-point box.
func dolphin() -> NSBezierPath {
    func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }
let d = NSBezierPath()
d.move(to: P(0.8, 11.0))                                   // beak
d.curve(to: P(3.6, 12.2), controlPoint1: P(1.6, 11.6), controlPoint2: P(2.8, 11.8))
d.curve(to: P(8.4, 15.0), controlPoint1: P(4.4, 14.4), controlPoint2: P(6.4, 15.2))      // melon and back
d.curve(to: P(11.4, 16.9), controlPoint1: P(9.6, 15.6), controlPoint2: P(10.6, 16.4))    // fin's front
d.curve(to: P(11.6, 14.1), controlPoint1: P(11.2, 16.0), controlPoint2: P(11.2, 15.0))   // fin's back
d.curve(to: P(15.6, 5.6), controlPoint1: P(14.4, 12.2), controlPoint2: P(15.8, 9.0))     // back to tail
d.curve(to: P(17.8, 3.2), controlPoint1: P(16.0, 4.4), controlPoint2: P(16.8, 3.6))      // upper fluke
d.curve(to: P(15.4, 2.8), controlPoint1: P(16.8, 2.6), controlPoint2: P(16.0, 2.5))
d.curve(to: P(15.4, 0.4), controlPoint1: P(15.0, 1.8), controlPoint2: P(15.2, 1.0))      // lower fluke
d.curve(to: P(13.6, 5.0), controlPoint1: P(14.0, 1.4), controlPoint2: P(13.6, 3.2))
d.curve(to: P(8.6, 10.2), controlPoint1: P(13.0, 7.6), controlPoint2: P(11.0, 9.4))      // belly
d.curve(to: P(7.0, 7.8), controlPoint1: P(7.8, 9.6), controlPoint2: P(7.4, 8.6))         // flipper
d.curve(to: P(6.2, 10.6), controlPoint1: P(6.4, 8.8), controlPoint2: P(6.0, 9.8))
d.curve(to: P(3.4, 10.4), controlPoint1: P(5.2, 10.8), controlPoint2: P(4.2, 10.6))      // throat
d.curve(to: P(0.8, 11.0), controlPoint1: P(2.4, 10.2), controlPoint2: P(1.4, 10.6))
d.close()
return d
}

func glyph() { dolphin().fill() }

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)

    // macOS icon grid: ~10% transparent margin around a rounded square.
    let body = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let square = NSBezierPath(roundedRect: body, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(starting: backTop, ending: backBottom)!.draw(in: square, angle: -90)

    // The menu bar icon's shape, white, filling the middle of the square. It's drawn on a layer of
    // its own, so the parts it cuts out show the square through rather than leaving holes.
    let layer = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: layer)
    let place = NSAffineTransform()
    place.translateX(by: s * 0.5, yBy: s * 0.5)
    place.scale(by: s * 0.56 / 18)
    place.translateX(by: -9, yBy: -9)
    place.concat()
    NSColor.white.set()
    glyph()
    NSGraphicsContext.restoreGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = backBottom.withAlphaComponent(0.45)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.shadowBlurRadius = s * 0.02
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    layer.draw(in: NSRect(x: 0, y: 0, width: s, height: s), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

if CommandLine.arguments.count > 1 {
    try! render(512).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    exit(0)
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MenuMySQL.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let out = URL(fileURLWithPath: "MenuMySQL/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
