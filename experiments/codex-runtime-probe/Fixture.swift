import AppKit

final class FixtureDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    private var window: NSWindow!
    private var counter = 0
    private let countLabel = NSTextField(labelWithString: "Counter: 0")
    private let input = NSTextField(string: "")
    private let statePath = ProcessInfo.processInfo.environment["SLZ_CUA_FIXTURE_STATE"]!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 140, y: 140, width: 520, height: 280), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Slz Runtime Fixture"
        window.isReleasedWhenClosed = false
        let heading = NSTextField(labelWithString: "Disposable Codex runtime test")
        heading.font = NSFont.systemFont(ofSize: 22)
        heading.frame = NSRect(x: 24, y: 222, width: 470, height: 32)
        countLabel.frame = NSRect(x: 24, y: 174, width: 180, height: 28)
        countLabel.setAccessibilityIdentifier("probe-counter")
        input.frame = NSRect(x: 24, y: 112, width: 460, height: 32)
        input.placeholderString = "Probe input"
        input.setAccessibilityLabel("Probe input")
        input.setAccessibilityIdentifier("probe-input")
        input.delegate = self
        let button = NSButton(title: "Increment", target: self, action: #selector(increment))
        button.frame = NSRect(x: 24, y: 42, width: 140, height: 38)
        button.bezelStyle = .rounded
        button.setAccessibilityIdentifier("probe-increment")
        for view in [heading, countLabel, input, button] { window.contentView!.addSubview(view) }
        window.orderFront(nil)
        writeState()
    }

    @objc private func increment() { counter += 1; countLabel.stringValue = "Counter: \(counter)"; writeState() }
    func controlTextDidChange(_ notification: Notification) { writeState() }
    private func writeState() {
        let value: [String: Any] = ["counter": counter, "text": input.stringValue, "pid": ProcessInfo.processInfo.processIdentifier]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: statePath), options: .atomic)
        }
    }
}

let application = NSApplication.shared
let delegate = FixtureDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
