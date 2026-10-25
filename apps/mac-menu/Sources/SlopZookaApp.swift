import AppKit
import ServiceManagement
import SwiftUI

@main
struct SlopZookaCompanionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        MenuBarExtra {
            CompanionPanel(model: delegate.model)
        } label: {
            MenuIcon(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = CompanionModel()
    private var terminating = false
    func applicationDidFinishLaunching(_ notification: Notification) { model.start() }
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

private struct MenuIcon: View {
    @ObservedObject var model: CompanionModel
    var body: some View {
        Image(nsImage: CompanionIcon.image(size: 22))
            .opacity(model.ready ? 1 : 0.45)
            .accessibilityLabel("SlopZooka: \(model.state)")
            .help("SlopZooka · \(model.state)")
    }
}

struct CompanionPanel: View {
    @ObservedObject var model: CompanionModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: CompanionIcon.image(size: 44, application: true))
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
