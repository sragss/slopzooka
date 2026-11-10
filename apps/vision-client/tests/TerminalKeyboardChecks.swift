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
private final class KeyboardProbe: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private var webView: WKWebView!
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
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
                print(viewport ? "PASS: automatic hardware input, explicit software keyboard mode, focus-preserving reconnect/interrupt/zoom, viewport fit, PTY resizes, and grid bounds"
                    : "PASS: hardware editing keys, Control-letter shortcuts, and modified WebKit arrows in both keyboard modes, application cursor mode, editing-only Return/Backspace/Delete, normal text, composition, and non-terminal fields")
                exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                exit(1)
            }
        }
    }
}
