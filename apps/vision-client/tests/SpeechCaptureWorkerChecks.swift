import Foundation

nonisolated private final class TestSession: SpeechCaptureSession {
    let attempt: SpeechCaptureAttempt
    let events: AsyncStream<String>.Continuation
    let startupGate: DispatchSemaphore?

    init(attempt: SpeechCaptureAttempt, events: AsyncStream<String>.Continuation, startupGate: DispatchSemaphore?) {
        self.attempt = attempt
        self.events = events
        self.startupGate = startupGate
    }

    func start() throws {
        precondition(!Thread.isMainThread, "Audio startup must leave the UI thread free")
        events.yield("starting")
        startupGate?.wait()
        try attempt.checkCancellation()
    }

    func finish() {
        precondition(!Thread.isMainThread)
        events.yield("finishing")
    }

    func stop() {
        precondition(!Thread.isMainThread)
        events.yield("stopped")
    }
}

@main
struct SpeechCaptureWorkerChecks {
    @MainActor
    static func main() async throws {
        let (events, output) = AsyncStream<String>.makeStream()
        var iterator = events.makeAsyncIterator()
        let gate = DispatchSemaphore(value: 0)
        let worker = SpeechCaptureWorker { attempt, _ in TestSession(attempt: attempt, events: output, startupGate: gate) }
        let cancelled = SpeechCaptureAttempt()
        let starting = Task { try await worker.start(attempt: cancelled) { _ in } }
        let first = await iterator.next()
        precondition(first == "starting", "The UI must run while hardware startup is blocked")
        worker.stop(attempt: cancelled)
        gate.signal()
        do {
            try await starting.value
            preconditionFailure("Cancelled startup cannot report readiness")
        } catch is CancellationError { }
        let stopped = await iterator.next()
        precondition(stopped == "stopped")
        print("PASS: blocked audio startup leaves the UI responsive and cancellation tears down without readiness")

        let (newEvents, newOutput) = AsyncStream<String>.makeStream()
        var next = newEvents.makeAsyncIterator()
        let nextWorker = SpeechCaptureWorker { attempt, _ in TestSession(attempt: attempt, events: newOutput, startupGate: nil) }
        let old = SpeechCaptureAttempt()
        try await nextWorker.start(attempt: old) { _ in }
        let oldStarted = await next.next()
        precondition(oldStarted == "starting")
        nextWorker.stop(attempt: old)
        let current = SpeechCaptureAttempt()
        try await nextWorker.start(attempt: current) { _ in }
        let oldStopped = await next.next(), currentStarted = await next.next()
        precondition(oldStopped == "stopped" && currentStarted == "starting")
        let cancelledReplacement = SpeechCaptureAttempt()
        cancelledReplacement.cancel()
        do {
            try await nextWorker.start(attempt: cancelledReplacement) { _ in }
            preconditionFailure("A cancelled replacement cannot start")
        } catch is CancellationError { }
        nextWorker.stop(attempt: old)
        await nextWorker.finish(attempt: old)
        await nextWorker.finish(attempt: current)
        let finished = await next.next()
        precondition(finished == "finishing", "Retired work must not stop or finalize the current microphone session")
        nextWorker.stop(attempt: current)
        let currentStopped = await next.next()
        precondition(currentStopped == "stopped")
        print("PASS: late stop/finalize commands cannot affect a replacement recording")

        let queued = SpeechCaptureAttempt()
        queued.cancel()
        let unusedWorker = SpeechCaptureWorker { _, _ in preconditionFailure("Cancelled queued work cannot construct hardware") }
        do {
            try await unusedWorker.start(attempt: queued) { _ in }
            preconditionFailure("Cancelled queued work cannot start")
        } catch is CancellationError { }
        print("PASS: cancellation before queued startup never constructs or activates audio hardware")
    }
}
