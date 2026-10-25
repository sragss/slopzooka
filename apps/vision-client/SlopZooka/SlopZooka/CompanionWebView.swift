import SwiftUI
import WebKit

struct CompanionWebView: UIViewRepresentable {
    let url: URL
    @Binding var loadState: TerminalLoadState
    let focusRequestToken: Int

    func makeCoordinator() -> TerminalSessionController { TerminalSessionController(loadState: $loadState) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "terminalState")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.load(url, in: webView)
        return webView
    }
    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.loadState = $loadState
        context.coordinator.load(url, in: webView)
        if context.coordinator.focusToken != focusRequestToken {
            context.coordinator.focusToken = focusRequestToken
            webView.evaluateJavaScript("window.slzFocusTerminal?.()")
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
    private var requestedURL: URL?
    init(loadState: Binding<TerminalLoadState>) { self.loadState = loadState }
    func load(_ url: URL, in webView: WKWebView) {
        guard requestedURL != url else { return }
        requestedURL = url
        DispatchQueue.main.async { self.loadState.wrappedValue = .loading("Connecting") }
        webView.load(CompanionAPI.authorized(URLRequest(url: url)))
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: String] else { return }
        switch body["state"] {
        case "running": loadState.wrappedValue = .loaded
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
        if let response = navigationResponse.response as? HTTPURLResponse, response.statusCode == 401 {
            loadState.wrappedValue = .failed("Pair with your Mac from the launcher, then reopen this terminal")
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let requestedURL else { return }
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
        decisionHandler(
            target.host == requestedURL.host && target.port == requestedURL.port && target.path == "/terminal"
                ? .allow : .cancel)
    }
}
