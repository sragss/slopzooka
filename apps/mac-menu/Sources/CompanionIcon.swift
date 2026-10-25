import AppKit

// One vector mark for the menu bar and the application icon.
enum CompanionIcon {
    static func image(size: CGFloat, application: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let transform = AffineTransform(scale: size / 32)
            (transform as NSAffineTransform).concat()
            if application {
                let tile = NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 30, height: 30), xRadius: 7, yRadius: 7)
                NSGradient(
                    starting: NSColor(red: 0.20, green: 0.26, blue: 0.42, alpha: 1),
                    ending: NSColor(red: 0.06, green: 0.09, blue: 0.17, alpha: 1))!.draw(in: tile, angle: -70)
                let inset = AffineTransform(translationByX: 4, byY: 4)
                (inset as NSAffineTransform).concat()
                (AffineTransform(scale: 0.75) as NSAffineTransform).concat()
            }
            let ink = application ? NSColor(red: 0.63, green: 0.94, blue: 0.85, alpha: 1) : NSColor.black
            ink.withAlphaComponent(application ? 0.45 : 1).setStroke()
            let back = NSBezierPath(roundedRect: NSRect(x: 10, y: 12, width: 20, height: 16), xRadius: 3, yRadius: 3)
            back.lineWidth = 1.8
            back.stroke()
            if application {
                NSColor(red: 0.10, green: 0.16, blue: 0.25, alpha: 1).setFill()
            } else {
                NSColor.clear.setFill()
            }
            let front = NSBezierPath(roundedRect: NSRect(x: 2, y: 4, width: 22, height: 17), xRadius: 3, yRadius: 3)
            if application {
                front.fill()
            } else {
                NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
                front.fill()
                NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
            }
            ink.setStroke()
            front.lineWidth = 1.8
            front.stroke()
            let cursor = NSBezierPath()
            cursor.move(to: NSPoint(x: 7, y: 15))
            cursor.line(to: NSPoint(x: 10, y: 12.5))
            cursor.line(to: NSPoint(x: 7, y: 10))
            cursor.move(to: NSPoint(x: 13, y: 10))
            cursor.line(to: NSPoint(x: 18, y: 10))
            cursor.lineWidth = 1.8
            cursor.lineCapStyle = .round
            cursor.lineJoinStyle = .round
            cursor.stroke()
            return true
        }
        image.isTemplate = !application
        return image
    }
}
