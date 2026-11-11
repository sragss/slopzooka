import AppKit
import Foundation

struct FixtureState: Codable {
    var nonce = "ready"
    var counter = 1
    var portrait = false
    var closed = false
    var covered = false
    var staticImage = false
}
@MainActor final class FixtureView: NSView {
    var state = FixtureState()
    var frameNumber = 0
    private let labels = (0..<6).map { _ in NSTextField(labelWithString: "") }
    override init(frame: NSRect) {
        super.init(frame: frame)
        for (index, label) in labels.enumerated() {
            label.font = NSFont.monospacedSystemFont(ofSize: index == 4 ? 14 : 24, weight: .medium)
            label.textColor = .white
            addSubview(label)
        }
    }
    required init?(coder: NSCoder) { fatalError("Fixture is programmatic") }
    func updateText() {
        let lines = ["Slz Native Preview", "Nonce: \(state.nonce)", "Count: \(state.counter)", "Frame: \(frameNumber)", "Small text: ABCDEFG abcdefg 0123456789", "This is the native Mac fixture."]
        for (index, text) in lines.enumerated() where labels[index].stringValue != text { labels[index].stringValue = text }
    }
    override func layout() {
        super.layout()
        for (index, label) in labels.enumerated() {
            label.frame = NSRect(x: 28, y: bounds.height - 65 - CGFloat(index) * 46, width: max(1, bounds.width - 56), height: 34)
        }
    }
    override func draw(_ dirty: NSRect) {
        NSColor(calibratedRed: 0.055, green: 0.15, blue: 0.24, alpha: 1).setFill(); bounds.fill()
        let progress = CGFloat(frameNumber % 120) / 120
        NSColor.systemOrange.setFill()
        NSRect(x: 24 + progress * max(1, bounds.width - 90), y: 25, width: 40, height: 24).fill()
    }
}
@main @MainActor struct MacFixture {
    static func main() {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let file = URL(fileURLWithPath: CommandLine.arguments[1])
        NSApplication.shared.setActivationPolicy(.accessory)
        let view = FixtureView()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 680, height: 410), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.title = "Slz Native Preview Fixture"
        window.orderFrontRegardless()
        var cover: NSWindow?
        var previous: FixtureState?
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            MainActor.assumeIsolated {
                if let data = try? Data(contentsOf: file), let state = try? JSONDecoder().decode(FixtureState.self, from: data) {
                    if previous?.portrait != state.portrait { window.setContentSize(state.portrait ? NSSize(width: 390, height: 740) : NSSize(width: 680, height: 410)) }
                    if previous?.closed != state.closed { if state.closed { window.close() } else { window.orderFrontRegardless() } }
                    if state.covered, previous?.portrait != state.portrait { cover?.setFrame(window.frame.insetBy(dx: -8, dy: -8), display: true) }
                    if previous?.covered != state.covered {
                        if state.covered {
                            let opaque = NSWindow(contentRect: window.frame.insetBy(dx: -8, dy: -8), styleMask: [.borderless], backing: .buffered, defer: false)
                            opaque.isReleasedWhenClosed = false
                            opaque.backgroundColor = .darkGray
                            opaque.level = .floating
                            opaque.orderFrontRegardless()
                            cover = opaque
                        } else { cover?.close(); cover = nil }
                    }
                    if previous?.nonce != state.nonce || previous?.counter != state.counter { view.needsDisplay = true }
                    view.state = state; previous = state
                }
                if !view.state.staticImage { view.frameNumber += 1; view.needsDisplay = true }
                view.updateText()
            }
        }
        withExtendedLifetime((window, timer)) { NSApplication.shared.run() }
    }
}
