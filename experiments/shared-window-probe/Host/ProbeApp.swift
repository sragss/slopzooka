import SwiftUI
import AppKit
import ApplicationServices

@main struct ProbeHostApp: App {
    @StateObject private var host = HostModel()
    var body: some Scene {
        WindowGroup("Shared Window Probe") {
            HostPanel(host: host).frame(minWidth: 680, minHeight: 560)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in host.stop() }
                .onAppear {
                    if CommandLine.arguments.contains("--serve"), !host.running {
                        host.lan = CommandLine.arguments.contains("--lan")
                        if let index = CommandLine.arguments.firstIndex(of: "--seconds"), CommandLine.arguments.count > index+1,
                           let seconds = Double(CommandLine.arguments[index+1]) { host.seconds = seconds }
                        do { try host.start() } catch { host.message = error.localizedDescription }
                    }
                }
        }
        WindowGroup("Probe Native Fixture", id: "fixture") { NativeFixture().frame(minWidth: 420, minHeight: 400) }
    }
}
struct HostPanel: View {
    @ObservedObject var host: HostModel
    @Environment(\.openWindow) private var openWindow
    @State private var selection: UInt32?
    @State private var viewerHost = ProcessInfo.processInfo.hostName
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Isolated sharing experiment").font(.title)
            Text(host.message).textSelection(.enabled)
            HStack {
                Toggle("Allow LAN", isOn: $host.lan).disabled(host.running)
                TextField("Seconds", value: $host.seconds, format: .number).frame(width: 90).disabled(host.running)
                Button("Arm / start server") { perform { try host.start() } }.disabled(host.running)
                Button("Stop all") { host.stop() }.disabled(!host.running)
            }
            Text("Desktop: \(host.statusText)").font(.system(.body, design: .monospaced))
            HStack {
                Button("Confirm I'm here and unlocked (30s lease)") { host.confirmLocal() }.disabled(!host.running)
                Button("Request capture access") { _ = CGRequestScreenCaptureAccess() }
                Button("Request Accessibility") { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
            }
            Text("The local confirmation is a diagnostic lease when macOS omits lock state. It is not proof of reliable automatic detection.").font(.caption)
            HStack {
                Button("Refresh windows") { Task { do { try await host.refresh() } catch { host.message = error.localizedDescription } } }
                Picker("Target", selection: $selection) {
                    Text("Choose a window").tag(nil as UInt32?)
                    ForEach(host.windows, id: \.windowID) { w in Text("\(w.owningApplication?.applicationName ?? "App"): \(w.title ?? "Untitled")").tag(w.windowID as UInt32?) }
                }
                Button("Share") {
                    if let selection { Task { do { _ = try await host.share(selection) } catch { host.message = error.localizedDescription } } }
                }.disabled(selection == nil || !host.running)
                Button("Open fixture") { openWindow(id: "fixture") }
            }
            List(host.targets) { target in
                VStack(alignment: .leading) {
                    Text(target.label)
                    Text("\(target.id) • \(target.state) • \(target.frames) frames • \(target.bytes / 1024) KiB").font(.caption.monospaced()).textSelection(.enabled)
                    if !target.error.isEmpty { Text(target.error).font(.caption).foregroundStyle(.orange) }
                }
            }.frame(minHeight: 120)
            if !host.connection.isEmpty {
                HStack {
                    TextField("Mac address for Vision", text: $viewerHost)
                    Button("Copy viewer connection") {
                        guard var config = try? JSONSerialization.jsonObject(with: Data(host.connection.utf8)) as? [String: Any] else { return }
                        config["host"] = viewerHost
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(String(data: jsonData(config), encoding: .utf8)!, forType: .string)
                    }
                }
                Text("Connection credentials are in the private run directory. Paste the copied configuration into ProbeViewer; use a reachable Mac LAN address.").font(.caption)
            }
        }.padding(20)
    }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { host.message = error.localizedDescription } }
}
struct NativeFixture: View {
    @State private var text = "Unfinished draft"
    @State private var count = 0
    @State private var enabled = false
    @State private var dialog = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Native fixture").font(.title)
            Text("Counter: \(count)").accessibilityIdentifier("counter")
            HStack { Button("Increment") { count += 1 }; Button("Show dialog") { dialog = true } }
            TextField("Draft", text: $text).accessibilityIdentifier("draft")
            Toggle("Test setting", isOn: $enabled).accessibilityIdentifier("setting")
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Live clock: \(context.date.formatted(date: .omitted, time: .standard))").monospacedDigit()
            }
            ScrollView { ForEach(0..<60) { i in Text("\(i): Fine text — red green blue — ABCDEFG 0123456789").font(.system(size: 13, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading) } }
        }.padding().alert("Probe dialog", isPresented: $dialog) { Button("Done", role: .cancel) {} }
    }
}
