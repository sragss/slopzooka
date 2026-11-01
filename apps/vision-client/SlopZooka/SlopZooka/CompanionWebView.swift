import SwiftUI
import WebKit

#if canImport(UIKit)
struct CompanionWebView: UIViewRepresentable {
    let url: URL
    let reloadToken: Int
    @Binding var loadState: TerminalLoadState
    let isActive: Bool
    let focusRequestToken: Int
    let interruptRequestToken: Int
    let zoom: Double

    func makeCoordinator() -> TerminalSessionController { TerminalSessionController(loadState: $loadState) }
    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.reloadToken = reloadToken
        context.coordinator.focusToken = focusRequestToken
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(
            source: TerminalKeyboard.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.add(context.coordinator, name: "terminalState")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        context.coordinator.requestZoom(zoom, in: webView)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.02, green: 0.03, blue: 0.04, alpha: 1)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.updateActivity(isActive, in: webView)
        context.coordinator.load(url, in: webView)
        return webView
    }
    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.loadState = $loadState
        context.coordinator.updateActivity(isActive, in: webView)
        let reload = context.coordinator.reloadToken != reloadToken
        context.coordinator.reloadToken = reloadToken
        context.coordinator.load(url, in: webView, force: reload)
        context.coordinator.requestZoom(zoom, in: webView)
        if context.coordinator.interruptToken != interruptRequestToken {
            context.coordinator.interruptToken = interruptRequestToken
            webView.evaluateJavaScript("window.slzInterruptTerminal?.()")
        }
        if context.coordinator.focusToken != focusRequestToken {
            context.coordinator.focusToken = focusRequestToken
            context.coordinator.requestFocus(in: webView, showKeyboard: true)
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
#endif

/// Owns the terminal document bridge. A loaded page is not a connected session.
@MainActor
final class TerminalSessionController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var loadState: Binding<TerminalLoadState>
    var focusToken = 0
    var interruptToken = 0
    var reloadToken = 0
    private var requestedURL: URL?
    private weak var webView: WKWebView?
    private var terminalReady = false
    private var isActive = false
    private var focusGeneration = 0
    // nil means no pending focus; false keeps physical typing ready without software UI.
    private var pendingFocus: Bool?
    private var zoom = 1.0

    func requestZoom(_ zoom: Double, in webView: WKWebView) {
        guard self.zoom != zoom else { return }
        self.zoom = zoom
        if terminalReady { applyZoom(in: webView) }
    }

    private func applyZoom(in webView: WKWebView) {
        // Scale the terminal font, not the web view's drawing surface. The web
        // bridge explicitly refits the emulator and sends its new grid to the PTY.
        webView.evaluateJavaScript("window.slzSetTerminalZoom?.(\(zoom))")
    }
    func updateActivity(_ active: Bool, in webView: WKWebView) {
        guard isActive != active else { return }
        isActive = active
        focusGeneration += 1
        if active { requestFocus(in: webView) }
        else { pendingFocus = nil }
    }
    func requestFocus(in webView: WKWebView, showKeyboard: Bool = false) {
        guard isActive else { return }
        pendingFocus = showKeyboard
        guard terminalReady else { return }
        pendingFocus = nil
        focusGeneration += 1
        let generation = focusGeneration
        // Set the keyboard mode before requesting native focus, otherwise a
        // previously requested software keyboard can briefly reopen on activation.
        webView.evaluateJavaScript("window.slzFocusTerminal?.(\(showKeyboard))") { [weak self, weak webView] _, _ in
            guard let self, self.isActive, self.terminalReady, self.focusGeneration == generation else { return }
            webView?.becomeFirstResponder()
        }
    }
    init(loadState: Binding<TerminalLoadState>) { self.loadState = loadState }
    func load(_ url: URL, in webView: WKWebView, force: Bool = false) {
        guard force || requestedURL != url else { return }
        requestedURL = url
        self.webView = webView
        terminalReady = false
        focusGeneration += 1
        pendingFocus = isActive ? false : nil
        DispatchQueue.main.async { self.loadState.wrappedValue = .loading("Connecting") }
        webView.load(CompanionAPI.authorized(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)))
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: String] else { return }
        switch body["state"] {
        case "running":
            terminalReady = true
            loadState.wrappedValue = .loaded
            if let webView { applyZoom(in: webView) }
            if let showKeyboard = pendingFocus, let webView { requestFocus(in: webView, showKeyboard: showKeyboard) }
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
        focusGeneration += 1
        // Restore physical typing without replaying an old software-keyboard request.
        pendingFocus = isActive ? false : nil
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
