import Foundation
import Security
import CryptoKit

struct ConnectionConfig: Codable, Equatable {
    var host: String
    var port: Int
    var token: String
    var fingerprint: String
    func request(_ path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        guard (1...65535).contains(port), token.count >= 32,
              fingerprint.count == 64, fingerprint.allSatisfy({ $0.isHexDigit }),
              !host.contains("/"), !host.contains("@") else { throw ProbeFailure("bad_configuration", "Invalid connection fields") }
        var parts = URLComponents(); parts.scheme = "https"; parts.host = host; parts.port = port; parts.path = path
        guard let url = parts.url else { throw ProbeFailure("bad_address", "Invalid host address") }
        var request = URLRequest(url: url); request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body; request.timeoutInterval = 15
        return request
    }
}
final class PinnedDelegate: NSObject, URLSessionDataDelegate {
    let fingerprint: String
    var data: ((Data) -> Void)?
    var finished: ((String?) -> Void)?
    init(_ fingerprint: String) { self.fingerprint = fingerprint.lowercased() }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificate = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        let actual = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        guard actual == fingerprint else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler((response as? HTTPURLResponse)?.statusCode == 200 ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive bytes: Data) { data?(bytes) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { finished?(error?.localizedDescription) }
}
func pinnedSession(_ delegate: PinnedDelegate) -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 7200
    let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
    return URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
}
