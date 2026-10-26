import Foundation

/// Wait for actual speech and a pause; background silence alone never submits.
struct SpeechEndpoint {
    private var lastActivity: TimeInterval = 0
    private var hasWords = false

    mutating func heardVoice(at time: TimeInterval) { lastActivity = time }
    mutating func received(_ text: String, at time: TimeInterval) {
        hasWords = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        lastActivity = time
    }
    func shouldFinish(at time: TimeInterval) -> Bool {
        hasWords && time - lastActivity >= 1.5
    }
}
