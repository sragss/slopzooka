import Foundation

private final class MJPEGDelegate: NSObject, URLSessionDataDelegate {
    let inbox: StreamInbox
    init(_ inbox: StreamInbox) { self.inbox = inbox }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { completionHandler(.cancel); return }
        // URLSession itself demultiplexes multipart responses, issuing another response
        // callback for each JPEG and stripping its MIME headers from data callbacks.
        if response.mimeType == "image/jpeg", (1...8*1024*1024).contains(response.expectedContentLength) {
            inbox.append(Data("Content-Length: \(response.expectedContentLength)\r\n\r\n".utf8))
            completionHandler(.allow)
        } else { completionHandler(response.mimeType == "multipart/x-mixed-replace" ? .allow : .cancel) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { inbox.append(data) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { inbox.finish(error?.localizedDescription) }
}
@MainActor final class MJPEGSource {
    var image: ((Data) -> Void)?
    var failed: ((String) -> Void)?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var reading: Task<Void, Never>?
    func start(_ url: URL) throws {
        guard url.scheme == "http", url.host == "127.0.0.1", url.port == 9117, url.user == nil,
              url.password == nil, url.query == nil, url.fragment == nil, ["", "/"].contains(url.path) else {
            throw ProbeFailure("mjpeg_scope", "This isolated adapter only accepts the owned loopback WDA port 9117")
        }
        let inbox = StreamInbox()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 86400
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: MJPEGDelegate(inbox), delegateQueue: queue)
        task = session?.dataTask(with: url); task?.resume()
        reading = Task { @MainActor [weak self] in
            var parser = MultipartJPEGParser(), lastFrame = uptime()
            while !Task.isCancelled {
                do {
                    let (bytes, error) = inbox.drain()
                    if let error { throw ProbeFailure("mjpeg_disconnected", error) }
                    if let image = try parser.append(bytes).last { lastFrame = uptime(); self?.image?(image) }
                    if uptime() - lastFrame > 5 { throw ProbeFailure("mjpeg_stalled", "No device JPEG for five seconds") }
                } catch { self?.failed?(error.localizedDescription); self?.stop(); return }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }
    func stop() { reading?.cancel(); task?.cancel(); session?.invalidateAndCancel(); reading = nil; task = nil; session = nil }
}
