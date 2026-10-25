import AppKit
import Combine
import ServiceManagement
import SwiftUI

@main
struct SlopZookaCompanionApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = CompanionModel()
    private var terminating = false
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var statusObservation: AnyCancellable?
    private var codeObservation: AnyCancellable?
    private let codeWindow = ConnectionCodeWindow()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Construct and lay out once, before the first click. Keep the same SwiftUI tree alive.
        let hosting = NSHostingController(rootView: CompanionPanel(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = false
        _ = hosting.view
        hosting.view.layoutSubtreeIfNeeded()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.image = CompanionIcon.image(size: 22)
            button.target = self
            button.action = #selector(togglePopover)
            // Show at press time, without waiting for release or system menu tracking.
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.setAccessibilityLabel("SlopZooka")
        }
        statusObservation = model.$state.combineLatest(model.$ready)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .sink { [weak self] state, ready in
                self?.statusItem?.button?.alphaValue = ready ? 1 : 0.45
                self?.statusItem?.button?.toolTip = "SlopZooka · \(state)"
            }
        codeObservation = model.$pairingDisplayUntil.combineLatest(model.$ready)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .sink { [weak self] until, ready in
                guard let self else { return }
                self.codeWindow.update(until: ready ? until : 0, model: self.model)
            }
        model.start()
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // No process, network, image generation, or view construction in the click path.
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        if model.sessions > 0 {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Quit SlopZooka?"
            alert.informativeText =
                "This ends \(model.sessions) active terminal session\(model.sessions == 1 ? "" : "s") and their attached dev servers. Closing the menu keeps everything running."
            alert.addButton(withTitle: "Keep Running")
            alert.addButton(withTitle: "Quit and End Sessions")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        terminating = true
        model.onStopped = { NSApp.reply(toApplicationShouldTerminate: true) }
        // Defer even the no-child case until AppKit has received terminateLater.
        Task { model.stop() }
        return .terminateLater
    }
}
