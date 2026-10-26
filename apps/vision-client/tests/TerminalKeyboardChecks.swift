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
        webView.loadHTMLString(fixture, baseURL: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            fputs("FAIL: WebKit keyboard test timed out\n", stderr)
            exit(1)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("runKeyboardChecks()") { result, error in
            guard error == nil, result as? String == "PASS" else {
                fputs("FAIL: \(error?.localizedDescription ?? String(describing: result))\n", stderr)
                exit(1)
            }
            print("PASS: floating Return, paragraph Return, hardware Enter, normal text, composition, and non-terminal fields")
            exit(0)
        }
    }
}
