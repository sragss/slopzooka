import Combine
import WebKit

/// Navigation history belongs to the live WebView, independently of window lifecycle.
@MainActor
final class BrowserNavigation: ObservableObject {
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false

    private weak var webView: WKWebView?
    private var observations: [NSKeyValueObservation] = []

    func attach(to webView: WKWebView) {
        self.webView = webView
        // Observe history directly: pushState and same-document navigation do not
        // necessarily finish a document load or call the navigation delegate.
        observations = [
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] webView, _ in
                self?.scheduleUpdate(from: webView)
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] webView, _ in
                self?.scheduleUpdate(from: webView)
            },
        ]
    }

    func detach(from webView: WKWebView) {
        guard self.webView === webView else { return }
        observations.removeAll()
        self.webView = nil
        scheduleUpdate(from: nil)
    }

    func goBack() {
        guard let webView, webView.canGoBack else { return }
        webView.goBack()
    }

    func goForward() {
        guard let webView, webView.canGoForward else { return }
        webView.goForward()
    }

    nonisolated private func scheduleUpdate(from webView: WKWebView?) {
        // KVO can fire while SwiftUI creates the view. Publish on the next turn,
        // and ignore callbacks queued by a WebView that has since been replaced.
        DispatchQueue.main.async { [weak self, weak webView] in
            guard let self, self.webView === webView else { return }
            self.canGoBack = webView?.canGoBack ?? false
            self.canGoForward = webView?.canGoForward ?? false
        }
    }
}
