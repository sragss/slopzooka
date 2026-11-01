import SwiftUI
import WebKit

struct BrowserWindowView: View {
    let previewID: String?

    @EnvironmentObject private var windows: WindowGateway
    @State private var loadState: BrowserLoadState = .idle

    var body: some View {
        Group {
            if let payload {
                ZStack(alignment: .top) {
                    if let url = payload.url {
                        PreviewWebView(url: url, certificateAuthority: payload.certificateAuthority,
                            loadState: $loadState, reloadToken: windows.reloadToken(for: payload.id))
                            .id(payload.id)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    } else {
                        ContentUnavailableView(
                            "Invalid Preview URL",
                            systemImage: "network.slash",
                            description: Text("SlopZooka could not open the preview surface.")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    HStack(spacing: 10) {
                        if let statusText = statusText {
                            Text(statusText)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(statusColor)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.regularMaterial, in: Capsule())
                        }

                        Spacer(minLength: 0)

                        Button {
                            windows.reload(id: payload.id)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        .padding(10)
                        .background(.regularMaterial, in: Circle())

                        Button {
                            windows.close(id: payload.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.headline.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .padding(12)
                        .background(.regularMaterial, in: Circle())
                    }
                    .padding(14)
                }
            } else {
                WindowRecoveryView(id: previewID)
            }
        }
    }

    private var payload: PreviewWindowPayload? {
        guard let previewID else {
            return nil
        }

        return windows.previewPayload(for: previewID)
    }

    private var statusText: String? {
        if let previewID, let error = windows.contentError(for: previewID) { return error }
        switch loadState {
        case .idle, .loaded:
            return nil
        case .loading:
            return "Loading Preview"
        case .failed(let message):
            return message
        }
    }

    private var statusColor: AnyShapeStyle {
        if let previewID, windows.contentError(for: previewID) != nil { return AnyShapeStyle(.red) }
        switch loadState {
        case .failed:
            return AnyShapeStyle(.red)
        case .idle, .loading, .loaded:
            return AnyShapeStyle(.secondary)
        }
    }
}

private enum BrowserLoadState: Equatable {
    case idle
    case loading(String)
    case loaded
    case failed(String)
}

private struct PreviewWebView: UIViewRepresentable {
    let url: URL
    let certificateAuthority: String?
    @Binding var loadState: BrowserLoadState
    let reloadToken: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(loadState: $loadState, fallbackURL: url, reloadToken: reloadToken,
            certificateAuthority: certificateAuthority)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        // Each frontend gets its own cookie store, including gateways on different ports of one host.
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = context.coordinator
        DispatchQueue.main.async {
            loadState = .loading(url.absoluteString)
        }
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.loadState = $loadState
        context.coordinator.previewTrust = PreviewTrust(endpoint: url, certificateAuthority: certificateAuthority)
        if context.coordinator.fallbackURL != url {
            context.coordinator.fallbackURL = url
            webView.load(URLRequest(url: url))
        } else if context.coordinator.reloadToken != reloadToken {
            // Reload the existing document and preserve its isolated cookies and navigation history.
            if webView.url == nil {
                webView.load(URLRequest(url: url))
            } else {
                webView.reload()
            }
        }
        context.coordinator.reloadToken = reloadToken
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadState: Binding<BrowserLoadState>
        var fallbackURL: URL
        var reloadToken: Int
        var previewTrust: PreviewTrust?

        init(loadState: Binding<BrowserLoadState>, fallbackURL: URL, reloadToken: Int, certificateAuthority: String?) {
            self.loadState = loadState
            self.fallbackURL = fallbackURL
            self.reloadToken = reloadToken
            self.previewTrust = PreviewTrust(endpoint: fallbackURL, certificateAuthority: certificateAuthority)
        }

        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            let protection = challenge.protectionSpace
            guard protection.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                let previewTrust, previewTrust.matches(host: protection.host, port: protection.port)
            else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            guard let trust = protection.serverTrust, previewTrust.evaluate(trust) else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            let currentURL = webView.url?.absoluteString ?? fallbackURL.absoluteString
            loadState.wrappedValue = .loading(currentURL)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loadState.wrappedValue = .loaded
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) {
            loadState.wrappedValue = .failed(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            loadState.wrappedValue = .failed(error.localizedDescription)
        }
    }
}
