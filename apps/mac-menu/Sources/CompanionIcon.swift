import AppKit

// M9-style WWII bazooka: long plain tube, muzzle lip, central grip, wire shoulder rest,
// and rear guard. Drawn as a template silhouette, not a modern RPG with an exposed warhead.
enum CompanionIcon {
    static func image(size: CGFloat, application: Bool = false) -> NSImage {
        let dimensions = NSSize(width: application ? size : size * 1.45, height: size)
        let image = NSImage(size: dimensions, flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let transform = NSAffineTransform()
            transform.scale(by: size / 32)
            transform.concat()
            if application {
                let tile = NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 30, height: 30), xRadius: 7, yRadius: 7)
                NSGradient(
                    starting: NSColor(red: 0.20, green: 0.26, blue: 0.42, alpha: 1),
                    ending: NSColor(red: 0.06, green: 0.09, blue: 0.17, alpha: 1))!.draw(in: tile, angle: -70)
            }
            let placement = NSAffineTransform()
            placement.translateX(by: application ? 16 : 23.2, yBy: 16)
            if application { placement.rotate(byDegrees: -32) }
            placement.scale(by: application ? 0.69 : 1.05)
            placement.translateX(by: -20, yBy: -14)
            placement.concat()
            (application ? NSColor(red: 0.63, green: 0.94, blue: 0.85, alpha: 1) : NSColor.black).set()

            // The uninterrupted, slender launch tube is the identifying feature.
            NSBezierPath(rect: NSRect(x: 3.5, y: 14, width: 32.5, height: 2.8)).fill()
            polygon([(1.5, 12.9), (3, 12.9), (5, 14), (5, 16.8), (3, 17.9), (1.5, 17.9)]).fill()
            NSBezierPath(rect: NSRect(x: 18.7, y: 13.4, width: 1.7, height: 4.0)).fill()
            NSBezierPath(rect: NSRect(x: 7.5, y: 16.8, width: 1.6, height: 1.7)).fill()

            // Angled pistol grip and open trigger guard; no rifle stock or magazine.
            polygon([(21.2, 14), (24, 14), (26, 7), (23.2, 6.3)]).fill()
            let trigger = NSBezierPath()
            trigger.move(to: NSPoint(x: 19.8, y: 14))
            trigger.line(to: NSPoint(x: 19.2, y: 10.6))
            trigger.curve(
                to: NSPoint(x: 23.7, y: 9.1), controlPoint1: NSPoint(x: 19, y: 8.5),
                controlPoint2: NSPoint(x: 21.8, y: 9.1))
            trigger.lineWidth = 1.3
            trigger.lineJoinStyle = .round
            trigger.stroke()

            // Open shoulder rest and protective rear cage survive as negative space at 22 pt.
            let rest = NSBezierPath()
            rest.move(to: NSPoint(x: 28, y: 14))
            rest.line(to: NSPoint(x: 27.2, y: 7.2))
            rest.line(to: NSPoint(x: 29.3, y: 7.2))
            rest.line(to: NSPoint(x: 33.7, y: 11.2))
            rest.line(to: NSPoint(x: 35, y: 11.2))
            rest.line(to: NSPoint(x: 35, y: 14))
            rest.lineWidth = 1.4
            rest.lineJoinStyle = .round
            rest.stroke()
            let guardFrame = NSBezierPath(
                roundedRect: NSRect(x: 35.5, y: 13.2, width: 3.5, height: 4.4), xRadius: 0.5, yRadius: 0.5)
            guardFrame.lineWidth = 1.3
            guardFrame.stroke()
            return true
        }
        image.isTemplate = !application
        return image
    }

    private static func polygon(_ points: [(CGFloat, CGFloat)]) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: points[0].0, y: points[0].1))
        for point in points.dropFirst() { path.line(to: NSPoint(x: point.0, y: point.1)) }
        path.close()
        return path
    }
}
