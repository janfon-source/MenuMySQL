import AppKit

/// The menu bar icon: a database cylinder with a dolphin's fin rising behind it, after MySQL's
/// mark, as a template image so it takes the menu bar's color.
enum StatusIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            // The cylinder: a solid body with its top rim and a band cut out of it.
            let left: CGFloat = 1.5, width: CGFloat = 11, rise: CGFloat = 3.6
            let body = NSBezierPath(rect: NSRect(x: left, y: 3.3, width: width, height: 10.2))
            body.append(NSBezierPath(ovalIn: NSRect(x: left, y: 1.5, width: width, height: rise)))
            body.append(NSBezierPath(ovalIn: NSRect(x: left, y: 11.7, width: width, height: rise)))
            body.fill()
            NSGraphicsContext.current?.compositingOperation = .clear
            for y: CGFloat in [11.2, 7.2] {
                // Only the front half of each ring shows.
                let path = NSBezierPath(ovalIn: NSRect(x: left, y: y, width: width, height: rise))
                path.lineWidth = 1.1
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: NSRect(x: 0, y: 0, width: 18, height: y + rise / 2)).addClip()
                path.stroke()
                NSGraphicsContext.restoreGraphicsState()
            }
            // A gap round the fin where it crosses the cylinder.
            let gap = fin()
            gap.lineWidth = 2.6
            gap.stroke()
            gap.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            fin().fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// A dolphin's back fin, rising out of the cylinder's right side to a point at the top right.
    private static func fin() -> NSBezierPath {
        let fin = NSBezierPath()
        fin.move(to: NSPoint(x: 10.5, y: 6.0))
        fin.curve(to: NSPoint(x: 17.2, y: 16.8), controlPoint1: NSPoint(x: 13.8, y: 8.4), controlPoint2: NSPoint(x: 16.4, y: 12.4))
        fin.curve(to: NSPoint(x: 11.4, y: 10.6), controlPoint1: NSPoint(x: 15.0, y: 14.6), controlPoint2: NSPoint(x: 13.2, y: 12.0))
        fin.close()
        return fin
    }
}
