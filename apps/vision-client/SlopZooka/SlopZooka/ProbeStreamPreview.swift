import SwiftUI
import UIKit
import CryptoKit
import Security

// Opt-in experiment receiver: one newest image, serial parsing, pinned TLS.
// Does not own presentation, app control, workspace or terminal lifetime.
private final class ProbeJPEGConnection: NSObject, URLSessionDataDelegate {
    let descriptor: ProbeStreamDescriptor
    private var session: URLSession?
    private var parser = ProbeMediaParser()
    private let lock = NSLock()
    private var latest: Data?
    private var generation = -1
    private var clear = false
    private var message = "Connecting"
    private var frames = 0
    private var lastBytes = Date()
    init(_ descriptor: ProbeStreamDescriptor) { self.descriptor = descriptor }
    func start() throws {
        guard (1...65535).contains(descriptor.port), descriptor.token.count >= 32,
              descriptor.fingerprint.count == 64 else { throw URLError(.badURL) }
        var parts = URLComponents(); parts.scheme = "https"; parts.host = descriptor.host; parts.port = descriptor.port
        parts.path = "/stream/\(descriptor.target)"
        guard let url = parts.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url); request.setValue("Bearer \(descriptor.token)", forHTTPHeaderField: "Authorization")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 7200
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        session?.dataTask(with: request).resume()
    }
    func stop() { session?.invalidateAndCancel(); session = nil }
    func take() -> (Data?, Bool, String, Bool) {
        lock.lock(); defer { lock.unlock() }
        let stale = Date().timeIntervalSince(lastBytes) > 3
        let value = latest; latest = nil
        let reset = clear || stale; clear = false
        return (stale ? nil : value, reset, stale ? "Stream unavailable" : "\(message) • \(frames) received", stale)
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let cert = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            return (.cancelAuthenticationChallenge, nil)
        }
        let hash = SHA256.hash(data: SecCertificateCopyData(cert) as Data).map { String(format: "%02x", $0) }.joined()
        guard hash == descriptor.fingerprint.lowercased() else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler((response as? HTTPURLResponse)?.statusCode == 200 ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            for (header, payload) in try parser.append(data) {
                lock.lock()
                lastBytes = Date()
                if generation != header.generation { generation = header.generation; latest = nil; clear = true }
                switch header.kind {
                case "jpeg": latest = payload; frames += 1; message = "Receiving"
                case "paused": latest = nil; clear = true; message = header.reason ?? "Paused"
                default:
                    message = header.reason ?? "Unknown source"
                    if !["browser_screencast", "device_mjpeg", "idle", "complete"].contains(message) { latest = nil; clear = true }
                }
                lock.unlock()
            }
        } catch { fail(error.localizedDescription) }
    }
    private func fail(_ reason: String) {
        lock.lock(); latest = nil; clear = true; message = reason; lastBytes = .distantPast; lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { fail(error?.localizedDescription ?? "Stream ended") }
}

struct ProbeStreamPreview: View {
    let descriptor: ProbeStreamDescriptor
    let report: (String) -> Void
    @State private var picture: UIImage?
    @State private var message = "Connecting"
    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            if let picture { Image(uiImage: picture).resizable().scaledToFit() }
            Text(message).font(.caption).padding().background(.regularMaterial)
        }.task(id: descriptor) {
            while !Task.isCancelled {
                let connection = ProbeJPEGConnection(descriptor)
                do {
                    try connection.start()
                    var lastReport = Date.distantPast
                    while !Task.isCancelled {
                        let (bytes, clear, state, stale) = connection.take()
                        if clear { picture = nil }
                        if let bytes { picture = UIImage(data: bytes) }
                        message = state
                        if Date().timeIntervalSince(lastReport) > 1 { report(state); lastReport = Date() }
                        if stale { break }
                        try await Task.sleep(for: .milliseconds(33))
                    }
                } catch { message = error.localizedDescription; report(message) }
                connection.stop(); picture = nil
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
            report("Receiver stopped")
        }
    }
}
