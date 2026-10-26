import SwiftUI
import WebKit

struct CompanionWebView: UIViewRepresentable {
    let url: URL
    @Binding var loadState: TerminalLoadState
    let focusRequestToken: Int
    let interruptRequestToken: Int
    let zoom: Double

    func makeCoordinator() -> TerminalSessionController { TerminalSessionController(loadState: $loadState) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(
            source: TerminalKeyboard.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.add(context.coordinator, name: "terminalState")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.pageZoom = CGFloat(zoom)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.02, green: 0.03, blue: 0.04, alpha: 1)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.load(url, in: webView)
        return webView
    }
    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.loadState = $loadState
        context.coordinator.load(url, in: webView)
        // Page zoom changes the CSS viewport; the terminal's ResizeObserver refits the PTY grid.
        if webView.pageZoom != CGFloat(zoom) { webView.pageZoom = CGFloat(zoom) }
        if context.coordinator.interruptToken != interruptRequestToken {
            context.coordinator.interruptToken = interruptRequestToken
            webView.evaluateJavaScript("window.slzInterruptTerminal?.()")
        }
        if context.coordinator.focusToken != focusRequestToken {
            context.coordinator.focusToken = focusRequestToken
            context.coordinator.requestFocus(in: webView)
        }
    }
    static func dismantleUIView(_ webView: WKWebView, coordinator: TerminalSessionController) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "terminalState")
        webView.evaluateJavaScript("window.slzDetachTerminal?.()")
        webView.navigationDelegate = nil
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }
}

/// Owns the terminal document bridge. A loaded page is not a connected session.
@MainActor
final class TerminalSessionController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var loadState: Binding<TerminalLoadState>
    var focusToken = 0
    var interruptToken = 0
    private var requestedURL: URL?
    private weak var webView: WKWebView?
    private var terminalReady = false
    private var pendingFocus = false
    func requestFocus(in webView: WKWebView) {
        pendingFocus = true
        guard terminalReady else { return }
        pendingFocus = false
        webView.becomeFirstResponder()
        webView.evaluateJavaScript("window.slzFocusTerminal?.()")
    }
    init(loadState: Binding<TerminalLoadState>) { self.loadState = loadState }
    func load(_ url: URL, in webView: WKWebView) {
        guard requestedURL != url else { return }
        requestedURL = url
        self.webView = webView
        terminalReady = false
        DispatchQueue.main.async { self.loadState.wrappedValue = .loading("Connecting") }
        webView.load(CompanionAPI.authorized(URLRequest(url: url)))
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: String] else { return }
        switch body["state"] {
        case "running":
            terminalReady = true
            loadState.wrappedValue = .loaded
            if pendingFocus, let webView { requestFocus(in: webView) }
        case "failed": loadState.wrappedValue = .failed(body["message"] ?? "Session unavailable")
        case "exited": loadState.wrappedValue = .ended(body["message"] ?? "Session ended")
        default: loadState.wrappedValue = .loading(body["message"] ?? "Connecting")
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadState.wrappedValue = .failed(error.localizedDescription)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadState.wrappedValue = .failed(error.localizedDescription)
    }
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.isForMainFrame,
            let response = navigationResponse.response as? HTTPURLResponse, response.statusCode >= 400 {
            loadState.wrappedValue = .failed(response.statusCode == 401
                ? "Pair with your Mac from the launcher, then reopen this terminal"
                : "Terminal page returned HTTP \(response.statusCode). Reopen the terminal or check the Mac logs.")
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let requestedURL else { return }
        terminalReady = false
        pendingFocus = true
        loadState.wrappedValue = .loading("Reconnecting")
        webView.load(CompanionAPI.authorized(URLRequest(url: requestedURL)))
    }
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let target = navigationAction.request.url, let requestedURL else {
            decisionHandler(.cancel)
            return
        }
        let allowed = TerminalNavigation.allows(target, document: requestedURL)
        if !allowed && navigationAction.targetFrame?.isMainFrame != false {
            loadState.wrappedValue = .failed("Terminal navigation was blocked: \(target.scheme ?? "unknown")://\(target.host ?? "unknown")\(target.path)")
        }
        decisionHandler(allowed ? .allow : .cancel)
    }
}
