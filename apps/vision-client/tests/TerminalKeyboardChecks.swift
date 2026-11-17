import AppKit
import WebKit

@main
struct TerminalKeyboardChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let probe = KeyboardProbe()
        app.delegate = probe
        withExtendedLifetime(probe) { app.run() }
    }
}

@MainActor
private final class KeyboardProbe: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    private var webView: WKWebView!
    private var window: NSWindow!
    private var latencySummaries: [[String: Any]] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(self, name: "diagnostics")
        configuration.userContentController.addUserScript(WKUserScript(
            source: TerminalKeyboard.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 400), configuration: configuration)
        webView.navigationDelegate = self
        window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = webView
        let fixture = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        if CommandLine.arguments.count > 2 {
            var url = URLComponents(url: URL(fileURLWithPath: CommandLine.arguments[1]), resolvingAgainstBaseURL: false)!
            url.queryItems = [URLQueryItem(name: "sessionId", value: "viewport-fixture")]
            if CommandLine.arguments[2] == "legacy" {
                url.queryItems?.append(URLQueryItem(name: "legacy", value: "1"))
            }
            webView.loadFileURL(url.url!, allowingReadAccessTo: url.url!.deletingLastPathComponent())
            window.orderFront(nil)
        } else {
            webView.loadHTMLString(fixture, baseURL: nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
            fputs("FAIL: WebKit keyboard test timed out\n", stderr)
            exit(1)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let viewport = CommandLine.arguments.count > 2
        Task { @MainActor in
            do {
                let function = viewport ? "runViewportChecks" : "runKeyboardChecks"
                let scripts = Dictionary(uniqueKeysWithValues: [0.1, 0.3, 0.5, 0.6, 0.7, 1.0, 2.0].map {
                    (String($0), TerminalZoom.script(scale: $0))
                })
                let result = try await webView.callAsyncJavaScript("""
                    window.applyNativeZoom = zoom => (0, eval)(zoomScripts[Number(zoom).toFixed(1)]);
                    return await \(function)();
                    """, arguments: ["zoomScripts": scripts], in: nil, contentWorld: .page)
                guard result as? String == "PASS" else { throw NSError(domain: "TerminalChecks", code: 1) }
                if viewport {
                    // Script messages arrive asynchronously across the real bridge.
                    for _ in 0..<20 where (latencySummaries.last?["pendingFrames"] as? Int) != 0 {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    guard latencySummaries.reduce(0, { $0 + ($1["outputFrames"] as? Int ?? 0) }) >= 1000,
                          latencySummaries.reduce(0, { $0 + ($1["inputAcks"] as? Int ?? 0) }) > 0,
                          latencySummaries.last?["pendingFrames"] as? Int == 0 else {
                        throw NSError(domain: "TerminalLatencySummary", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "Missing complete latency summary: \(latencySummaries)"])
                    }
                }
                if viewport, let burst = try await webView.evaluateJavaScript("JSON.stringify(window.fixtureBurst)") as? String {
                    print("PASS: real WebKit tiny-frame burst \(burst)")
                }
                print(viewport ? "PASS: automatic hardware input, explicit software keyboard mode, focus-preserving reconnect/interrupt/zoom, viewport fit, PTY resizes, and grid bounds"
                    : "PASS: committed capitals/Unicode without keypress, modifier matrix, F1–F12/navigation, Control shortcuts, composition, and non-terminal fields in both keyboard modes")
                exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                exit(1)
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let event = message.body as? [String: Any], event["event"] as? String == "latency.summary",
              let fields = event["fields"] as? [String: Any] else { return }
        latencySummaries.append(fields)
    }
}
