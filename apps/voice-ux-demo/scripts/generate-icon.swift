import AppKit
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
for layer in ["Back", "Middle", "Front"] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    if layer == "Back" {
        NSGradient(starting: NSColor(calibratedRed: 0.14, green: 0.17, blue: 0.27, alpha: 1),
                   ending: NSColor(calibratedRed: 0.04, green: 0.05, blue: 0.10, alpha: 1))!
            .draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024), angle: 90)
    } else if layer == "Middle" {
        NSColor.white.withAlphaComponent(0.06).setFill()
        NSBezierPath(ovalIn: NSRect(x: 170, y: 170, width: 684, height: 684)).fill()
        NSColor.white.withAlphaComponent(0.20).setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: 170, y: 170, width: 684, height: 684))
        ring.lineWidth = 5
        ring.stroke()
    } else {
        NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 427, y: 425, width: 170, height: 300), xRadius: 85, yRadius: 85).fill()
        NSColor(calibratedWhite: 0.93, alpha: 1).setStroke()
        let stand = NSBezierPath()
        stand.lineWidth = 34
        stand.lineCapStyle = .round
        stand.move(to: NSPoint(x: 356, y: 522))
        stand.line(to: NSPoint(x: 356, y: 480))
        stand.curve(to: NSPoint(x: 668, y: 480), controlPoint1: NSPoint(x: 356, y: 270), controlPoint2: NSPoint(x: 668, y: 270))
        stand.line(to: NSPoint(x: 668, y: 522))
        stand.move(to: NSPoint(x: 512, y: 326))
        stand.line(to: NSPoint(x: 512, y: 258))
        stand.move(to: NSPoint(x: 438, y: 258))
        stand.line(to: NSPoint(x: 586, y: 258))
        stand.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    let url = root.appendingPathComponent("\(layer).solidimagestacklayer/Content.imageset/\(layer).png")
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}
