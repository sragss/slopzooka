import Foundation

// Delegate callbacks write here instead of scheduling an unbounded number of main-actor
// tasks. A fresh inbox belongs to each connection, so old callbacks cannot affect a retry.
final class StreamInbox: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var bytes = Data()
    private var failure: String?
    init(limit: Int = 10 * 1024 * 1024) { self.limit = limit }
    func append(_ data: Data) {
        lock.withLock {
            guard failure == nil else { return }
            guard bytes.count + data.count <= limit else {
                bytes.removeAll(); failure = "Receiver queue exceeded limit"; return
            }
            bytes.append(data)
        }
    }
    func finish(_ error: String?) {
        lock.withLock { failure = failure ?? error ?? "Connection ended" }
    }
    func drain() -> (Data, String?) {
        lock.withLock {
            let result = (bytes, failure); bytes = Data(); return result
        }
    }
}
