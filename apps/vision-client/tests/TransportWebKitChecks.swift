import AppKit
import WebKit

/// Test-only observer around real WebSockets; production terminal rendering,
/// input, acknowledgements, and reconnection are unchanged.
@main
struct TransportWebKitChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let probe = TransportWebKitProbe()
        app.delegate = probe
        withExtendedLifetime(probe) { app.run() }
    }
}

@MainActor
private final class TransportWebKitProbe: NSObject, NSApplicationDelegate, WKScriptMessageHandler {
    private var windows: [NSWindow] = []
    private var views: [WKWebView] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                let args = CommandLine.arguments
                for (index, sessionID) in args.dropFirst(3).enumerated() {
                    let configuration = WKWebViewConfiguration()
                    configuration.websiteDataStore = .nonPersistent()
                    configuration.userContentController.add(self, name: "diagnostics")
                    configuration.userContentController.addUserScript(WKUserScript(source: """
                        window.fixtureReceived = []; window.fixtureSent = [];
                        const NativeSocket = WebSocket;
                        window.WebSocket = class extends NativeSocket {
                          constructor(...args) {
                            super(...args);
                            this.addEventListener('message', event => fixtureReceived.push(JSON.parse(event.data)));
                          }
                          send(data) { fixtureSent.push(JSON.parse(data)); super.send(data); }
                        };
                        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
                    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 360), configuration: configuration)
                    let window = NSWindow(contentRect: NSRect(x: 40 + index * 80, y: 40, width: 640, height: 360),
                                          styleMask: [.titled], backing: .buffered, defer: false)
                    window.title = "Slz Transport Regression \(index + 1)"
                    window.contentView = view
                    window.orderBack(nil) // No app activation or keyboard-focus takeover.
                    windows.append(window); views.append(view)
                    var url = URLComponents(string: args[1])!
                    url.path = "/terminal"
                    url.queryItems = [URLQueryItem(name: "sessionId", value: sessionID)]
                    var request = URLRequest(url: url.url!)
                    request.setValue("Bearer \(args[2])", forHTTPHeaderField: "Authorization")
                    view.load(request)
                }
                for view in views {
                    try await until(view, "document.querySelector('#connection-overlay')?.hidden === true && document.querySelector('#read-only')?.hidden === true")
                }
                report(["ready": true])
                for try await phase in FileHandle.standardInput.bytes.lines {
                    guard ["before", "after"].contains(phase) else { throw URLError(.badURL) }
                    for (index, view) in views.enumerated() {
                        let input = "\(phase)-\(index)"
                        let hex = input.utf8.map { String(format: "%02x", $0) }.joined()
                        _ = try await view.evaluateJavaScript("""
                            (() => {
                              const input = document.querySelector('.xterm-helper-textarea');
                              input.dispatchEvent(new KeyboardEvent('keydown', {key: 'Unidentified', keyCode: 0, bubbles: true, cancelable: true}));
                              input.dispatchEvent(new InputEvent('beforeinput', {inputType: 'insertText', data: '\(input)', bubbles: true, cancelable: true}));
                              input.dispatchEvent(new KeyboardEvent('keyup', {key: 'Unidentified', keyCode: 0, bubbles: true}));
                            })(); 0
                            """)
                        try await until(view, """
                            fixtureReceived.some(message => message.type === 'output' && message.data.includes('RECEIVED:\(hex)') &&
                              fixtureSent.some(ack => ack.type === 'ack' && ack.cursor >= message.cursor))
                            """)
                    }
                    report(["phase": phase, "checked": views.count])
                }
                for view in views { view.loadHTMLString("", baseURL: nil) }
                for window in windows { window.orderOut(nil) }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("WebKit transport check: \(error)\n".utf8))
                exit(1)
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // Keep only connection metadata, never terminal input or credentials.
        if let body = message.body as? [String: Any], let event = body["event"] as? String,
           event.hasPrefix("connection."), let fields = body["fields"] as? [String: Any] {
            report(["event": event, "sessionId": fields["sessionId"] ?? "", "attempt": fields["attempt"] ?? 0])
        }
    }
    private func until(_ view: WKWebView, _ expression: String) async throws {
        for _ in 0..<160 {
            if (try? await view.evaluateJavaScript(expression)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw URLError(.timedOut)
    }
    private func report(_ value: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: value)
        FileHandle.standardOutput.write(data + Data([10]))
    }
}
