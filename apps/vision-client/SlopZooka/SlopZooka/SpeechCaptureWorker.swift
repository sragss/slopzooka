import Foundation

/// A session is constructed, used, and released exclusively on the capture queue.
nonisolated protocol SpeechCaptureSession: AnyObject {
    var attempt: SpeechCaptureAttempt { get }
    func start() throws
    func finish()
    func stop()
}

/// Cancellation is visible even while the worker is blocked in audio startup.
nonisolated final class SpeechCaptureAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.withLock { cancelled = true } }
    func checkCancellation() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
}

/// All hardware and speech-framework setup/teardown belongs to this serial queue.
/// The main actor receives only value snapshots; it never waits synchronously for audio.
nonisolated final class SpeechCaptureWorker: @unchecked Sendable {
    enum Event: Sendable {
        case levels([Double], heardVoice: Bool, producedAt: TimeInterval)
        case timing([String: Double])
        case recognition(String, isFinal: Bool, hasMetadata: Bool, error: String?)
        case availability(Bool)
    }

    private let queue = DispatchQueue(label: "com.samragsdale.SlopZooka.speech", qos: .userInitiated)
    // Accessed only on queue. The audio tap owns its own meter on the audio thread.
    private var session: (any SpeechCaptureSession)?
    private let makeSession: @Sendable (SpeechCaptureAttempt, @escaping @Sendable (Event) -> Void) -> any SpeechCaptureSession

    init(makeSession: @escaping @Sendable (SpeechCaptureAttempt, @escaping @Sendable (Event) -> Void) -> any SpeechCaptureSession) {
        self.makeSession = makeSession
    }

    func start(attempt: SpeechCaptureAttempt, emit: @escaping @Sendable (Event) -> Void) async throws {
        try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                var starting: (any SpeechCaptureSession)?
                do {
                    try attempt.checkCancellation()
                    session?.stop()
                    session = nil
                    let next = makeSession(attempt, emit)
                    starting = next
                    try next.start()
                    try attempt.checkCancellation()
                    session = next
                    reply.resume()
                } catch {
                    starting?.stop()
                    reply.resume(throwing: error)
                }
            }
        }
    }

    func finish(attempt: SpeechCaptureAttempt) async {
        await withCheckedContinuation { reply in
            queue.async { [self] in
                if session?.attempt === attempt { session?.finish() }
                reply.resume()
            }
        }
    }

    func stop(attempt: SpeechCaptureAttempt) {
        attempt.cancel()
        queue.async { [self] in
            guard session?.attempt === attempt else { return }
            session?.stop()
            session = nil
        }
    }
}
