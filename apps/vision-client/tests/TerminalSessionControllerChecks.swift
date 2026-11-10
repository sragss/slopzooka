import AppKit
import SwiftUI
import WebKit

// Keep authentication out of the local document fixture.
enum CompanionClient {
    static func authorized(_ request: URLRequest) -> URLRequest { request }
}

@main
struct TerminalSessionControllerChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let probe = FocusProbe()
        app.delegate = probe
        withExtendedLifetime(probe) { app.run() }
    }
}

@MainActor
private final class FixtureWebView: WKWebView {
    var generation = 0

    override func load(_ request: URLRequest) -> WKNavigation? {
        generation += 1
        return loadHTMLString("""
            <script>
            window.fixtureGeneration = \(generation);
            window.focusRequests = [];
            window.slzFocusTerminal = showKeyboard => focusRequests.push(showKeyboard);
            window.ready = () => webkit.messageHandlers.terminalState.postMessage({state: 'running'});
            </script>
            """, baseURL: request.url)
    }
}

@MainActor
private final class FocusProbe: NSObject, NSApplicationDelegate {
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                var state = TerminalLoadState.idle
                let controller = TerminalSessionController(loadState: Binding(get: { state }, set: { state = $0 }))
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                configuration.userContentController.add(controller, name: "terminalState")
                configuration.userContentController.add(controller, name: "terminalNotification")
                let webView = FixtureWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 400), configuration: configuration)
                window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = webView
                window.orderFront(nil)
                let url = URL(string: "http://localhost/terminal?sessionId=fixture")!

                controller.updateActivity(true, in: webView)
                controller.load(url, in: webView)
                try await documentReady(webView)
                try await ready(webView, expecting: [false])
                precondition(state == .loaded)
                var alerts: [Int] = []
                var selections = 0
                controller.onNotification = { sequence, instance in
                    precondition(instance == "fixture")
                    alerts.append(sequence)
                    return true
                }
                controller.onSelect = { selections += 1 }
                _ = try await webView.evaluateJavaScript("""
                    webkit.messageHandlers.terminalNotification.postMessage({kind: 'alert', sequence: 2, serviceInstanceId: 'fixture', audible: true});
                    webkit.messageHandlers.terminalNotification.postMessage({kind: 'alert', sequence: -1, serviceInstanceId: 'fixture'});
                    webkit.messageHandlers.terminalNotification.postMessage({kind: 'alert', sequence: true, serviceInstanceId: 'fixture'});
                    webkit.messageHandlers.terminalNotification.postMessage({kind: 'alert', sequence: 1.5, serviceInstanceId: 'fixture'});
                    webkit.messageHandlers.terminalNotification.postMessage({kind: 'selected'});
                    0
                    """)
                try await until { alerts == [2] && selections == 1 }
                precondition(state == .loaded, "alerts and selection must not change terminal connection state")
                // Repeated running messages and SwiftUI updates must not refocus.
                controller.updateActivity(true, in: webView)
                try await ready(webView, expecting: [false])
                controller.requestFocus(in: webView, showKeyboard: true)
                try await expect(webView, [false, true])
                controller.updateActivity(false, in: webView)
                controller.requestFocus(in: webView, showKeyboard: true)
                try await ready(webView, expecting: [false, true])
                controller.updateActivity(true, in: webView)
                try await expect(webView, [false, true, false])

                // A backgrounded scene must discard requests queued before readiness.
                controller.load(url, in: webView, force: true)
                controller.requestFocus(in: webView, showKeyboard: true)
                controller.updateActivity(false, in: webView)
                try await documentReady(webView)
                try await ready(webView, expecting: [])
                controller.updateActivity(true, in: webView)
                try await expect(webView, [false])

                // Recovery restores physical typing, never an old software request.
                controller.requestFocus(in: webView, showKeyboard: true)
                try await expect(webView, [false, true])
                controller.webViewWebContentProcessDidTerminate(webView)
                try await documentReady(webView)
                try await ready(webView, expecting: [false])
                controller.updateActivity(false, in: webView)
                controller.webViewWebContentProcessDidTerminate(webView)
                try await documentReady(webView)
                try await ready(webView, expecting: [])
                // Companion restart/disconnect keeps activation intent queued until running.
                controller.updateActivity(true, in: webView)
                try await expect(webView, [false])
                _ = try await webView.evaluateJavaScript("webkit.messageHandlers.terminalState.postMessage({state: 'disconnected'}); 0")
                try await until { state == .disconnected }
                controller.updateActivity(false, in: webView)
                controller.updateActivity(true, in: webView)
                try await expect(webView, [false])
                try await ready(webView, expecting: [false, false])
                _ = try await webView.evaluateJavaScript("webkit.messageHandlers.terminalState.postMessage({state: 'disconnected'}); 0")
                try await until { state == .disconnected }
                controller.requestFocus(in: webView, showKeyboard: true)
                try await expect(webView, [false, false])
                try await ready(webView, expecting: [false, false, true])
                print("PASS: native activation restores hardware focus, explicit Keyboard requests software UI, background cancels pending focus, and recovery respects scene activity")
                exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                exit(1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            fputs("FAIL: native terminal focus checks timed out\n", stderr)
            exit(1)
        }
    }

    private func documentReady(_ webView: FixtureWebView) async throws {
        try await until {
            let generation = try await webView.evaluateJavaScript("window.fixtureGeneration || 0") as? Int
            return generation == webView.generation
        }
    }

    private func ready(_ webView: WKWebView, expecting requests: [Bool]) async throws {
        _ = try await webView.evaluateJavaScript("window.ready(); 0")
        try await expect(webView, requests)
    }

    private func expect(_ webView: WKWebView, _ requests: [Bool]) async throws {
        // A JS round trip also drains bridge calls queued by the running message.
        _ = try await webView.evaluateJavaScript("0")
        let actual = try await webView.evaluateJavaScript("window.focusRequests") as? [Bool]
        precondition(actual == requests, "Expected focus requests \(requests), got \(String(describing: actual))")
    }

    private func until(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<120 {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 16_000_000)
        }
        throw NSError(domain: "TerminalFocusChecks", code: 1)
    }
}
