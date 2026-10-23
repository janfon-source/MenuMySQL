import AppKit

/// The menu bar icon: a leaping dolphin, after MySQL's mark, as one solid shape, in the same
/// plain style as 隨手SQLite's feather and 隨手記's pen; a template image, so it takes the menu
/// bar's color.
enum StatusIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            dolphin().fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// The dolphin, beak at the left, arching over to its tail at the bottom right.
    private static func dolphin() -> NSBezierPath {
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
}
