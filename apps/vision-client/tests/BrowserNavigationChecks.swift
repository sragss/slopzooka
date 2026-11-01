import AppKit
import WebKit

@main
struct BrowserNavigationChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let probe = NavigationProbe()
        app.delegate = probe
        withExtendedLifetime(probe) { app.run() }
    }
}

private final class FixtureSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let response = URLResponse(url: urlSchemeTask.request.url!, mimeType: "text/html",
            expectedContentLength: -1, textEncodingName: "utf-8")
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(Data("<p>Navigation fixture</p>".utf8))
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

@MainActor
private final class NavigationProbe: NSObject, NSApplicationDelegate {
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                let navigation = BrowserNavigation()
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                configuration.setURLSchemeHandler(FixtureSchemeHandler(), forURLScheme: "fixture")
                let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 400), configuration: configuration)
                window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = webView
                window.orderFront(nil)
                navigation.attach(to: webView)
                precondition(!navigation.canGoBack && !navigation.canGoForward)
                navigation.goBack()
                navigation.goForward()

                // Same-document navigation must update buttons without a page load.
                webView.load(URLRequest(url: URL(string: "fixture://preview/first")!))
                try await until { !webView.isLoading && webView.url != nil }
                _ = try await webView.evaluateJavaScript("history.pushState({}, '', '#second'); 0")
                try await until { navigation.canGoBack && !navigation.canGoForward }
                navigation.goBack()
                try await until { !navigation.canGoBack && navigation.canGoForward }
                navigation.goForward()
                try await until { navigation.canGoBack && !navigation.canGoForward }

                navigation.goBack()
                try await until { navigation.canGoForward }
                _ = try await webView.evaluateJavaScript("history.pushState({}, '', '#third'); 0")
                try await until { navigation.canGoBack && !navigation.canGoForward }
                precondition(webView.url?.fragment == "third")

                // Full document navigation and reload retain the same history.
                webView.load(URLRequest(url: URL(string: "fixture://preview/document")!))
                try await until { !webView.isLoading && webView.url?.path == "/document" }
                navigation.goBack()
                try await until { webView.url?.fragment == "third" && navigation.canGoForward }
                navigation.goForward()
                try await until { webView.url?.path == "/document" && !navigation.canGoForward }
                let historyCount = webView.backForwardList.backList.count
                webView.reload()
                try await until { !webView.isLoading }
                precondition(webView.backForwardList.backList.count == historyCount)
                precondition(navigation.canGoBack && !navigation.canGoForward)

                // Old observations and dismantle callbacks must not affect a replacement.
                let replacement = WKWebView(frame: webView.frame, configuration: configuration)
                navigation.detach(from: webView)
                navigation.attach(to: replacement)
                navigation.detach(from: webView)
                try await until { !navigation.canGoBack && !navigation.canGoForward }
                replacement.load(URLRequest(url: URL(string: "fixture://preview/replacement")!))
                window.contentView = replacement
                try await until { !replacement.isLoading && replacement.url != nil }
                _ = try await replacement.evaluateJavaScript("history.pushState({}, '', '#replacement'); 0")
                try await until { navigation.canGoBack }
                _ = try await webView.evaluateJavaScript("history.back(); 0")
                try await until { webView.canGoForward }
                precondition(navigation.canGoBack && !navigation.canGoForward)
                navigation.goBack()
                try await until { !navigation.canGoBack && navigation.canGoForward }
                navigation.detach(from: replacement)
                try await until { !navigation.canGoBack && !navigation.canGoForward }
                navigation.goBack()
                navigation.goForward()
                print("PASS: preview buttons follow back/forward and branching SPA history, and reset safely on replacement")
                exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                exit(1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            fputs("FAIL: browser navigation checks timed out\n", stderr)
            exit(1)
        }
    }

    private func until(line: Int = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<240 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 16_000_000)
        }
        throw NSError(domain: "BrowserNavigationChecks", code: line, userInfo: [NSLocalizedDescriptionKey: "Condition timed out at line \(line)"])
    }
}
