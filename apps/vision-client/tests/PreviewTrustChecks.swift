import AppKit
import Foundation
import Security
import WebKit

@MainActor
final class PreviewBrowserCheck: NSObject, WKNavigationDelegate {
    let browser = WKWebView(frame: .zero, configuration: {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        return config
    }())
    let previewTrust: PreviewTrust
    init(_ previewTrust: PreviewTrust) {
        self.previewTrust = previewTrust
        super.init()
        browser.navigationDelegate = self
    }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            previewTrust.matches(host: challenge.protectionSpace.host, port: challenge.protectionSpace.port),
            let trust = challenge.protectionSpace.serverTrust, previewTrust.evaluate(trust)
        else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task {
            do {
                let value = try await webView.callAsyncJavaScript("""
            if (!window.isSecureContext) throw new Error('Not a secure context');
            await fetch('/login', {method: 'POST'});
            const session = await fetch('/session');
            if (session.status !== 200) throw new Error('Secure login cookie was lost: ' + session.status);
            if (document.cookie.includes('app_session')) throw new Error('HttpOnly cookie exposed');
            return 'PASS: WebKit secure context and Secure/HttpOnly login session';
            """, arguments: [:], in: nil, contentWorld: .page)
                print(value ?? "PASS"); exit(0)
            } catch { print(error); exit(1) }
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print(error); exit(1)
    }
}

@main
struct PreviewTrustChecks {
    @MainActor
    static func main() throws {
        let args = CommandLine.arguments
        let endpoint = URL(string: args[1])!
        let ca = try Data(contentsOf: URL(fileURLWithPath: args[2])).base64EncodedString()
        let leaf = SecCertificateCreateWithData(nil, try Data(contentsOf: URL(fileURLWithPath: args[3])) as CFData)!
        let foreign = try Data(contentsOf: URL(fileURLWithPath: args[4])).base64EncodedString()
        let trusted = PreviewTrust(endpoint: endpoint, certificateAuthority: ca)!
        func trust() -> SecTrust {
            var result: SecTrust?
            precondition(SecTrustCreateWithCertificates([leaf] as CFArray, SecPolicyCreateSSL(true, nil), &result) == errSecSuccess)
            return result!
        }
        precondition(trusted.matches(host: endpoint.host!, port: endpoint.port!))
        precondition(!trusted.matches(host: "unrelated.invalid", port: endpoint.port!))
        precondition(!trusted.matches(host: endpoint.host!, port: endpoint.port! + 1))
        precondition(trusted.evaluate(trust()), "The companion's valid certificate must be accepted")
        let wrongHost = PreviewTrust(endpoint: URL(string: "https://wrong.invalid")!, certificateAuthority: ca)!
        precondition(!wrongHost.evaluate(trust()), "A valid CA must not bypass hostname validation")
        let wrongCA = PreviewTrust(endpoint: endpoint, certificateAuthority: foreign)!
        precondition(!wrongCA.evaluate(trust()), "An unrelated CA must be rejected")
        let expired = trust()
        SecTrustSetVerifyDate(expired, Date().addingTimeInterval(60 * 24 * 60 * 60) as CFDate)
        precondition(!trusted.evaluate(expired), "Expired leaf certificates must be rejected")
        print("PASS: native certificate hostname, endpoint, authority, and expiry checks")

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let check = PreviewBrowserCheck(trusted)
        check.browser.load(URLRequest(url: endpoint))
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { print("WebKit login check timed out"); exit(1) }
        withExtendedLifetime(check) { app.run() }
    }
}
