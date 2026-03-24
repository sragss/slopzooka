import SwiftUI
import WebKit

struct CompanionWebView: UIViewRepresentable {
    let url: URL
    @Binding var loadState: TerminalLoadState
    let focusRequestToken: Int
    let pendingInputToken: Int
    let pendingInputText: String?
    let pendingInputSendReturn: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(loadState: $loadState, fallbackURL: url)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = context.coordinator
        DispatchQueue.main.async {
            loadState = .loading(url.absoluteString)
        }
        Task { @MainActor in
            slzLog("webview makeUIView \(url.absoluteString)")
        }
        context.coordinator.currentRequestedURLString = url.absoluteString
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.loadState = $loadState
        context.coordinator.fallbackURL = url
        if context.coordinator.lastFocusRequestToken != focusRequestToken {
            context.coordinator.lastFocusRequestToken = focusRequestToken
            focusTerminal(in: webView)
        }
        if context.coordinator.lastInputToken != pendingInputToken,
           let pendingInputText {
            context.coordinator.lastInputToken = pendingInputToken
            sendInput(pendingInputText, sendReturn: pendingInputSendReturn, to: webView)
        }
        guard context.coordinator.currentRequestedURLString != url.absoluteString else {
            return
        }

        context.coordinator.currentRequestedURLString = url.absoluteString
        DispatchQueue.main.async {
            loadState = .loading(url.absoluteString)
        }
        Task { @MainActor in
            slzLog("webview updateUIView \(url.absoluteString)")
        }
        webView.load(URLRequest(url: url))
    }

    private func focusTerminal(in webView: WKWebView) {
        let script = """
        if (typeof window.slzFocusTerminal === 'function') {
            window.slzFocusTerminal();
        } else if (document.body) {
            document.body.focus();
        }
        """
        webView.evaluateJavaScript(script)
    }

    private func sendInput(_ text: String, sendReturn: Bool, to webView: WKWebView) {
        guard let data = try? JSONSerialization.data(withJSONObject: [text, sendReturn]),
              let encoded = String(data: data, encoding: .utf8) else {
            return
        }

        let script = """
        const args = \(encoded);
        window.__slzQueuedTerminalInputs = window.__slzQueuedTerminalInputs || [];
        window.__slzQueuedTerminalInputs.push({ text: args[0], sendReturn: args[1] });
        if (typeof window.slzEnqueueTerminalInput === 'function') {
            window.slzEnqueueTerminalInput(args[0], args[1]);
        }
        """
        webView.evaluateJavaScript(script)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadState: Binding<TerminalLoadState>
        var fallbackURL: URL
        var lastFocusRequestToken = 0
        var lastInputToken = 0
        var currentRequestedURLString: String?

        init(loadState: Binding<TerminalLoadState>, fallbackURL: URL) {
            self.loadState = loadState
            self.fallbackURL = fallbackURL
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            let currentURL = webView.url?.absoluteString ?? fallbackURL.absoluteString
            loadState.wrappedValue = .loading(currentURL)
            Task { @MainActor in
                slzLog("webview start \(currentURL)")
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loadState.wrappedValue = .loaded
            Task { @MainActor in
                slzLog("webview loaded \(webView.url?.absoluteString ?? fallbackURL.absoluteString)")
            }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) {
            loadState.wrappedValue = .failed(error.localizedDescription)
            Task { @MainActor in
                slzLog("webview provisional fail \(error.localizedDescription)")
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            loadState.wrappedValue = .failed(error.localizedDescription)
            Task { @MainActor in
                slzLog("webview fail \(error.localizedDescription)")
            }
        }
    }
}
