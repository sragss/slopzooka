import Foundation

/// Text belongs to an utterance, whose lifetime can be shorter than a speech task.
/// On-device recognition can publish utterance metadata without setting isFinal,
/// then replace its hypothesis with the next utterance (or an empty final result).
struct SpeechRecognitionSegment {
    private(set) var transcript = ""

    /// Returns whether this utterance should be committed before accepting more audio.
    mutating func receive(_ text: String, isFinal: Bool, hasUtteranceMetadata: Bool,
        isFinishing: Bool = false, hasError: Bool = false) -> Bool {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            transcript = text
        }
        // endAudio can report an error instead of a final result; the last
        // nonempty hypothesis still completes the requested Send or rotation.
        return isFinal || (hasUtteranceMetadata && !transcript.isEmpty) || (isFinishing && hasError)
    }

    /// Leave time to finalize and rearm before the framework's one-minute task limit.
    static func shouldRotate(elapsed: TimeInterval) -> Bool { elapsed >= 50 }
}
