import Foundation

/// Five adjacent energy measurements from the newest 20 ms of audio. The bars
/// update together, rather than retaining four older audio callbacks. Smoothing
/// belongs only to the display, so capture cadence cannot add an envelope delay.
nonisolated struct SpeechLevelMeter {
    private(set) var levels = Array(repeating: 0.0, count: 5)

    mutating func receive(samples: UnsafeBufferPointer<Float>, sampleRate: Double) -> [Double] {
        guard sampleRate > 0, samples.count >= levels.count else {
            levels = Array(repeating: 0, count: 5)
            return levels
        }
        let count = min(samples.count, max(levels.count, Int(sampleRate * 0.02)))
        let offset = samples.count - count
        for bar in levels.indices {
            let start = offset + count * bar / levels.count
            let end = offset + count * (bar + 1) / levels.count
            var energy: Float = 0
            for index in start..<end { energy += samples[index] * samples[index] }
            let rms = sqrt(Double(energy) / Double(end - start))
            let decibels = 20 * log10(max(rms, 0.000001))
            levels[bar] = min(1, max(0, (decibels + 55) / 45))
        }
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
