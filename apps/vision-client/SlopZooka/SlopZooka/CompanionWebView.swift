import SwiftUI
import WebKit

struct CompanionWebView: UIViewRepresentable {
    let url: URL
    @Binding var loadState: TerminalLoadState
    let focusRequestToken: Int

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
        guard webView.url != url else {
            return
        }

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

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadState: Binding<TerminalLoadState>
        var fallbackURL: URL
        var lastFocusRequestToken = 0

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
