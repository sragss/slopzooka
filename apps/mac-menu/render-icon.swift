import AppKit

@main
struct RenderIcon {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Inspect the actual menu glyph at native, Retina, and enlarged sizes.
        for scale in [1, 2, 8] {
            let image = CompanionIcon.image(size: CGFloat(22 * scale))
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(ceil(image.size.width)), pixelsHigh: Int(image.size.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSColor.white.setFill()
            NSRect(origin: .zero, size: image.size).fill()
            image.draw(in: NSRect(origin: .zero, size: image.size))
            NSGraphicsContext.restoreGraphicsState()
            try bitmap.representation(using: .png, properties: [:])!.write(
                to: directory.deletingLastPathComponent().appendingPathComponent("MenuBar-\(scale)x.png"))
        }
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = size * scale
                let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                CompanionIcon.image(size: CGFloat(pixels), application: true).draw(
                    in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
                NSGraphicsContext.restoreGraphicsState()
                let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
                try bitmap.representation(using: .png, properties: [:])!.write(
                    to: directory.appendingPathComponent(name))
            }
        }
    }
}
