// Renders MenuMySQL/AppIcon.icns.  Run from MenuMySQLMac/:  swift tools/make_icon.swift
// With a path (swift tools/make_icon.swift preview.png), writes a 512px preview there instead.
import AppKit

// MySQL's colors: its teal blue behind, going deeper, and its orange for the dolphin's fin.
let backTop = NSColor(red: 0.000, green: 0.459, blue: 0.561, alpha: 1)
let backBottom = NSColor(red: 0.000, green: 0.208, blue: 0.290, alpha: 1)
let disk = NSColor(red: 0.937, green: 0.973, blue: 0.980, alpha: 1)
let edge = NSColor(red: 0.553, green: 0.761, blue: 0.808, alpha: 1)
let ink = NSColor(red: 0.000, green: 0.255, blue: 0.333, alpha: 1)
let feather = NSColor(red: 0.949, green: 0.569, blue: 0.067, alpha: 1)

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

    // A database: a cylinder, its top seen from above, with a band round its front. It sits a
    // little left, to leave room for the feather.
    let width = s * 0.44, rise = s * 0.12           // the ellipses' width and height
    let left = s * 0.22
    let bottom = s * 0.24, top = s * 0.66            // centers of the bottom and top ellipses
    let line = s * 0.014
    func oval(_ center: CGFloat) -> NSRect { NSRect(x: left, y: center - rise / 2, width: width, height: rise) }

    let side = NSBezierPath(rect: NSRect(x: left, y: bottom, width: width, height: top - bottom))
    side.append(NSBezierPath(ovalIn: oval(bottom)))
    disk.setFill()
    side.fill()

    // The band and the bottom rim: only the front half of each ellipse shows.
    edge.setStroke()
    for center in [bottom, top - (top - bottom) * 0.28] {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: s, height: center)).addClip()
        let band = NSBezierPath(ovalIn: oval(center))
        band.lineWidth = line
        band.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
    let topFace = NSBezierPath(ovalIn: oval(top))
    NSColor.white.setFill()
    topFace.fill()
    topFace.lineWidth = line
    topFace.stroke()

    // "My" across the front, below the band: MySQL, at a glance.
    let text = NSAttributedString(string: "My", attributes: [
        .font: NSFont.systemFont(ofSize: s * 0.135, weight: .heavy),
        .foregroundColor: ink,
        .kern: s * 0.004,
    ])
    let size = text.size()
    let textMid = bottom + (top - (top - bottom) * 0.28 - bottom) / 2 - rise * 0.12
    text.draw(at: NSPoint(x: left + (width - size.width) / 2, y: textMid - size.height / 2))

    // A leaping dolphin's curve over the cylinder's right, after MySQL's mark: a body arching
    // up from low right to a nose at the top, with a tail fin at its foot.
    NSGraphicsContext.saveGraphicsState()
    square.addClip()
    let dolphin = NSBezierPath()
    dolphin.move(to: NSPoint(x: s * 0.66, y: s * 0.86))                                     // the nose
    dolphin.curve(to: NSPoint(x: s * 0.80, y: s * 0.22), controlPoint1: NSPoint(x: s * 0.92, y: s * 0.84), controlPoint2: NSPoint(x: s * 0.96, y: s * 0.40))
    dolphin.curve(to: NSPoint(x: s * 0.72, y: s * 0.74), controlPoint1: NSPoint(x: s * 0.84, y: s * 0.42), controlPoint2: NSPoint(x: s * 0.84, y: s * 0.66))
    dolphin.curve(to: NSPoint(x: s * 0.66, y: s * 0.86), controlPoint1: NSPoint(x: s * 0.68, y: s * 0.77), controlPoint2: NSPoint(x: s * 0.64, y: s * 0.80))
    dolphin.close()
    // The tail: two flukes spread at the body's foot.
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: s * 0.80, y: s * 0.26))
    tail.line(to: NSPoint(x: s * 0.70, y: s * 0.17))
    tail.curve(to: NSPoint(x: s * 0.80, y: s * 0.19), controlPoint1: NSPoint(x: s * 0.74, y: s * 0.17), controlPoint2: NSPoint(x: s * 0.78, y: s * 0.18))
    tail.curve(to: NSPoint(x: s * 0.88, y: s * 0.12), controlPoint1: NSPoint(x: s * 0.83, y: s * 0.16), controlPoint2: NSPoint(x: s * 0.86, y: s * 0.13))
    tail.line(to: NSPoint(x: s * 0.84, y: s * 0.27))
    tail.close()
    // A dorsal fin on the back of the arch.
    let fin = NSBezierPath()
    fin.move(to: NSPoint(x: s * 0.86, y: s * 0.66))
    fin.curve(to: NSPoint(x: s * 0.95, y: s * 0.74), controlPoint1: NSPoint(x: s * 0.90, y: s * 0.70), controlPoint2: NSPoint(x: s * 0.93, y: s * 0.72))
    fin.curve(to: NSPoint(x: s * 0.89, y: s * 0.56), controlPoint1: NSPoint(x: s * 0.93, y: s * 0.66), controlPoint2: NSPoint(x: s * 0.92, y: s * 0.60))
    fin.close()
    // Drawn a little smaller and further in, so the dolphin stays inside the square.
    var place = AffineTransform(translationByX: s * 0.5, byY: s * 0.5)
    place.scale(0.86)
    place.translate(x: -s * 0.62, y: -s * 0.5)
    for shape in [dolphin, tail, fin] { shape.transform(using: place) }
    for shape in [dolphin, tail, fin] {
        backBottom.withAlphaComponent(0.55).setStroke()
        shape.lineWidth = s * 0.022
        shape.stroke()
    }
    feather.setFill()
    for shape in [dolphin, tail, fin] { shape.fill() }
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
