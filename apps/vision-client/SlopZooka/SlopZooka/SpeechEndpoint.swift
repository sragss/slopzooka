import Foundation

/// A short envelope of microphone energy, with fast attack and a softer release.
/// Keeps raw audio out of observable UI state; silence settles back to zero.
struct SpeechLevelMeter {
    private var level = 0.0
    private(set) var levels = Array(repeating: 0.0, count: 5)

    mutating func receive(rms: Float) -> [Double] {
        let decibels = 20 * log10(max(Double(rms), 0.000001))
        let target = min(1, max(0, (decibels + 55) / 45))
        level += (target - level) * (target > level ? 0.7 : 0.3)
        if level < 0.01 { level = 0 }
        levels.removeFirst()
        levels.append(level)
        return levels
    }
}

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
