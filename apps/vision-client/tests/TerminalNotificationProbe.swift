import AppKit
import AVFAudio
import SwiftUI
import WebKit

// The probe serves one synthetic terminal on loopback, with no pairing secrets.
enum CompanionClient {
    static func authorized(_ request: URLRequest) -> URLRequest { request }
}

@main
struct TerminalNotificationProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let probe = NotificationProbe()
        app.delegate = probe
        withExtendedLifetime(probe) { app.run() }
    }
}

@MainActor
private final class NotificationProbe: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var controller: TerminalSessionController!
    private var loadState = TerminalLoadState.idle
    private var notifications = TerminalNotifications()
    private var player: AVAudioPlayer?
    private var playbackRequests = 0
    private let status = NSTextField(labelWithString: "Starting isolated terminal…")
    private let url = URL(string: CommandLine.arguments[1])!
    private let resultFile = URL(fileURLWithPath: CommandLine.arguments[2])
    private let interactive = CommandLine.arguments.contains("--interactive")
    private var checking = false

    private struct Snapshot: Decodable {
        let attachments: Int
        let processes: Int
        let focusOuts: Int
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = TerminalSessionController(loadState: Binding(get: { self.loadState }, set: { self.loadState = $0 }))
        controller.onNotification = { [weak self] sequence, instance in
            guard let self else { return false }
            let fresh = self.notifications.receive(sequence: sequence, serviceInstanceID: instance)
            self.render()
            return fresh
        }
        controller.onSelect = { [weak self] in
            guard let self else { return }
            self.notifications.markRead()
            self.controller.updateActivity(true, in: self.webView)
            self.render()
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(controller, name: "terminalState")
        // Observe the same production bridge alongside the controller so the Mac
        // probe can exercise the original WAV; scene anchoring requires visionOS.
        configuration.userContentController.add(self, name: "terminalNotification")
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = controller
        webView.wantsLayer = true
        let bar = NSStackView(views: [status,
            button("Background", #selector(backgroundTerminal)),
            button("Focus", #selector(focusTerminal)),
            button("Bell", #selector(ring)),
            button("Reload", #selector(reload))])
        bar.orientation = .horizontal
        bar.spacing = 12
        let content = NSView()
        for view in [bar, webView!] {
            content.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            webView.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 12),
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: 650),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "SlopZooka Notification Probe — isolated PTY"
        window.contentView = content
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
        controller.updateActivity(true, in: webView)
        controller.load(url, in: webView)
        runChecks()
    }

    func windowWillClose(_ notification: Notification) {
        if checking { try? "FAIL: checks cancelled\n".write(to: resultFile, atomically: true, encoding: .utf8) }
        exit(checking ? 1 : 0)
    }
    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    @objc private func backgroundTerminal() { controller.updateActivity(false, in: webView) }
    @objc private func focusTerminal() { controller.updateActivity(true, in: webView) }
    @objc private func ring() {
        Task {
            do { try await request("/probe/emit/b", method: "POST") }
            catch { status.stringValue = error.localizedDescription }
        }
    }
    @objc private func reload() { controller.load(url, in: webView, force: true) }

    private func render() {
        webView?.layer?.borderWidth = notifications.hasUnread ? 5 : 0
        webView?.layer?.borderColor = NSColor.systemOrange.cgColor
        if !checking { status.stringValue = notifications.hasUnread ? "Unread notification" : "Ready — Background triggers a focus-aware alert" }
    }

    @objc private func runChecks() {
        guard !checking else { return }
        checking = true
        Task { @MainActor in
            do {
                try await until("terminal attachment") { self.loadState == .loaded }
                try check(notifications.sequence == 0, "fresh terminal must have no historical alerts")
                status.stringValue = "Checking focus-out → PTY → bell → native border/audio…"
                backgroundTerminal()
                try await until("focus-out alert from real PTY") { self.notifications.sequence == 1 }
                try check(notifications.hasUnread && webView.layer?.borderWidth == 5, "native unread state must show an orange border")
                try check(playbackRequests == 1, "live BEL must start the bundled chime")
                print("PASS: native deactivation → DEC focus-out → real PTY BEL → native unread border and accepted audio playback")

                focusTerminal()
                _ = try await webView.evaluateJavaScript("document.getElementById('terminal').dispatchEvent(new PointerEvent('pointerdown', {bubbles: true})); 0")
                try await until("selection acknowledgement") { !self.notifications.hasUnread }
                try await request("/probe/emit/o", method: "POST")
                try await until("OSC 9 alert") { self.notifications.sequence == 2 }
                backgroundTerminal()
                try await until("second focus-out alert") { self.notifications.sequence == 3 }
                let before = try await snapshot()
                let cues = playbackRequests
                status.stringValue = "Checking inactive reload and replay deduplication…"
                reload()
                try await until("reattachment focus report") {
                    let state = try await self.snapshot()
                    return state.attachments > before.attachments && state.focusOuts > before.focusOuts && self.loadState == .loaded
                }
                try await Task.sleep(for: .milliseconds(300))
                try check(notifications.sequence == 3 && playbackRequests == cues, "reloading must not replay sound or generate another focus transition")
                try await request("/probe/emit/m", method: "POST")
                try await until("OSC 777 alert") { self.notifications.sequence == 4 }
                let beforeOffline = playbackRequests
                status.stringValue = "Checking an alert emitted while disconnected…"
                try await request("/probe/offline", method: "POST")
                try await until("silent missed-alert recovery") { self.notifications.sequence == 5 && self.loadState == .loaded }
                try check(playbackRequests == beforeOffline, "missed notifications recover silently")
                let final = try await snapshot()
                try check(final.processes == 1, "reconnection must keep exactly one PTY")
                print("PASS: OSC 9/777, selection acknowledgement, inactive reload focus restoration, silent offline recovery, and one retained PTY")
                try "PASS: focus-aware PTY bell, native unread border, accepted chime playback, OSC 9/777, selection, inactive reload, silent offline recovery, and one retained PTY\n".write(to: resultFile, atomically: true, encoding: .utf8)
                status.stringValue = "All checks passed — use Background, Focus, Bell, and Reload to try it"
                checking = false
                if !interactive { exit(0) }
            } catch {
                var report = "FAIL: \(error.localizedDescription)\n"
                fputs("FAIL: \(error.localizedDescription)\n", stderr)
                if let state = try? await snapshot() {
                    report += "Probe state: \(loadState); sequence=\(notifications.sequence); attachments=\(state.attachments); focusOuts=\(state.focusOuts); processes=\(state.processes)\n"
                }
                try? report.write(to: resultFile, atomically: true, encoding: .utf8)
                status.stringValue = "Failed: \(error.localizedDescription)"
                checking = false
                if !interactive { exit(1) }
            }
        }
    }

    private func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "NotificationProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    private func until(_ label: String, condition: () async throws -> Bool) async throws {
        for _ in 0..<300 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "NotificationProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "Timed out: \(label)"])
    }
    private func request(_ route: String, method: String = "GET") async throws {
        var request = URLRequest(url: URL(string: route, relativeTo: url)!)
        request.httpMethod = method
        let (_, response) = try await URLSession.shared.data(for: request)
        try check((response as? HTTPURLResponse)?.statusCode == 204, "probe command failed")
    }
    private func snapshot() async throws -> Snapshot {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "/probe/state", relativeTo: url)!)
        return try JSONDecoder().decode(Snapshot.self, from: data)
    }
}

extension NotificationProbe: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        let previous = notifications.sequence
        controller.userContentController(userContentController, didReceive: message)
        guard notifications.sequence > previous, body["audible"] as? Bool == true else { return }
        do {
            if player == nil {
                player = try AVAudioPlayer(contentsOf: Bundle.main.url(forResource: "terminal-notification", withExtension: "wav")!)
                player?.volume = 0.5
            }
            player?.currentTime = 0
            if player?.play() == true { playbackRequests += 1 }
        } catch { fputs("Audio failed: \(error.localizedDescription)\n", stderr) }
    }
}
