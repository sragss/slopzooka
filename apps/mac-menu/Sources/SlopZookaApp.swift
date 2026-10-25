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

struct CompanionPanel: View {
    @ObservedObject var model: CompanionModel
    private static let icon = CompanionIcon.image(size: 44, application: true)
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: Self.icon)
                VStack(alignment: .leading, spacing: 4) {
                    Text("SlopZooka").font(.headline)
                    HStack(spacing: 5) {
                        Circle().fill(model.ready ? Color.green : Color.orange).frame(width: 6, height: 6)
                        Text(model.state).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            Text(model.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.ready {
                HStack {
                    Label("\(model.sessions) terminals", systemImage: "terminal")
                    Spacer()
                    Label("\(model.frontends) frontends", systemImage: "globe")
                }.font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Text("PAIR VISION PRO").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    HStack {
                        Text(model.code).font(.system(size: 20, weight: .medium, design: .monospaced)).textSelection(
                            .enabled)
                        Spacer()
                        Button {
                            model.copyCode()
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless).help("Copy pairing code")
                    }
                }
                .padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                Button("Open Dashboard") { NSWorkspace.shared.open(model.dashboard) }
                    .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
            } else if model.state == "Needs attention" {
                Button("Try Again") { model.retryStart() }.buttonStyle(.borderedProminent)
            }
            Divider()
            Toggle("Start at Login", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                .toggleStyle(.switch).controlSize(.small)
            if let notice = model.loginNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
                Button("Login Settings…") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(.link)
            }
            HStack {
                Button("View Logs") { NSWorkspace.shared.open(model.logDirectory) }
                Spacer()
                Button("Quit…") { NSApp.terminate(nil) }
            }.buttonStyle(.borderless).font(.callout)
        }
        .padding(20).frame(width: 320)
    }
}
