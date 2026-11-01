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
                let result = try await webView.callAsyncJavaScript("return await \(function)()", arguments: [:], in: nil, contentWorld: .page)
                guard result as? String == "PASS" else { throw NSError(domain: "TerminalChecks", code: 1) }
                print(viewport ? "PASS: explicit keyboard focus, passive open/reconnect/interrupt/zoom, viewport fit, PTY resizes, and grid bounds"
                    : "PASS: floating Return, paragraph Return, hardware Enter, normal text, composition, and non-terminal fields")
                exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                exit(1)
            }
        }
    }
}
