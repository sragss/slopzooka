import Foundation

@MainActor
private final class FakeSpeechCapture: SpeechCapturing {
    var state: SpeechCaptureState = .idle { didSet { onUpdate?() } }
    var transcript = "" { didSet { onUpdate?() } }
    var audioLevels = Array(repeating: 0.0, count: 5) { didSet { onUpdate?() } }
    var onUpdate: (() -> Void)?
    var onFinished: (() -> Void)?
    var starts = 0
    var completedStarts = 0
    var finishOnPause = true
    var permission: CheckedContinuation<Void, Never>?
    var delayPermission = false
    private var recording: UUID?

    func startListening(finishOnPause: Bool) async {
        defer { completedStarts += 1 }
        guard recording == nil else { preconditionFailure("Two microphone owners") }
        let id = UUID()
        recording = id
        starts += 1
        self.finishOnPause = finishOnPause
        transcript = ""
        state = .preparing
        if delayPermission { await withCheckedContinuation { permission = $0 } }
        guard recording == id else { return }
        state = .listening
    }
    func finishListening() { state = .finishing }
    func stopListening() { recording = nil; audioLevels = Array(repeating: 0, count: 5); state = .idle }
    func clearTranscript() { transcript = "" }
    func finish(_ text: String) {
        transcript = text
        stopListening()
        onFinished?()
    }
}

@main
struct TerminalVoiceChecks {
    @MainActor
    static func main() async {
        let suite = "TerminalVoiceChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let capture = FakeSpeechCapture()
        var available = Set(["a", "b"])
        var commands: [TerminalVoiceCommand] = []
        var completedDeliveries = 0
        var reply: CheckedContinuation<Void, Error>?
        let voice = TerminalVoiceController(capture: capture, defaults: defaults,
            isAvailable: { available.contains($0) }, deliver: { command in
                defer { completedDeliveries += 1 }
                commands.append(command)
                try await withCheckedThrowingContinuation { reply = $0 }
            })

        precondition(!voice.conversationEnabled, "Persistent recording is opt-in")
        voice.activateTerminal("a")
        await until { capture.state == .listening }
        precondition(capture.finishOnPause)
        capture.finish("one\r\nshot")
        await until { reply != nil }
        precondition(commands.last?.text == "one\nshot" && commands.last?.targetID == "a")
        reply!.resume(); reply = nil
        await until { voice.mode == nil }
        print("PASS: disabling persistent voice preserves one-shot pause-to-send dictation")

        voice.conversationEnabled = true
        precondition(defaults.bool(forKey: "conversationVoiceEnabled"))
        precondition(capture.state == .idle, "Enabling the feature does not start the microphone")
        let restoredCapture = FakeSpeechCapture()
        let restored = TerminalVoiceController(capture: restoredCapture, defaults: defaults,
            isAvailable: { _ in true }, deliver: { _ in preconditionFailure("Restoration cannot submit input") })
        precondition(restored.conversationEnabled && restored.mode == nil && restoredCapture.starts == 0,
            "Only the preference persists; listening and target selection do not restore")
        voice.activateTerminal("a")
        await until { capture.state == .listening }
        precondition(!capture.finishOnPause)
        capture.audioLevels = [0, 0.2, 0.7, 0.5, 0.1]
        precondition(voice.audioLevels == capture.audioLevels, "The selected terminal renders actual capture levels")
        capture.transcript = "first segment"
        let count = commands.count
        let starts = capture.starts
        capture.finish("first corrected segment")
        await until { capture.starts > starts && capture.state == .listening }
        precondition(commands.count == count, "Recognizer finalization must not press Return")
        capture.transcript = "second segment"
        precondition(voice.transcript == "first corrected segment second segment")
        voice.activateTerminal("b")
        precondition(voice.targetID == "a" && voice.hasText, "A draft cannot jump to another terminal")
        voice.send()
        precondition(capture.state == .finishing && commands.count == count)
        capture.finish("second corrected segment")
        await until { reply != nil }
        precondition(commands.last?.text == "first corrected segment second corrected segment")
        precondition(commands.last?.targetID == "a")
        reply!.resume(); reply = nil
        await until { capture.state == .listening }
        precondition(voice.targetID == "a" && !voice.hasText && !voice.isSubmitting)
        print("PASS: pauses and recognition segments keep one draft; explicit Send stays on its terminal and rearms")

        capture.transcript = "keep this draft"
        available.remove("a")
        voice.targetUnavailable("a")
        precondition(capture.state == .idle && voice.transcript == "keep this draft")
        available.insert("a")
        precondition(capture.state == .idle, "Reconnect cannot silently restart the microphone")
        voice.resume()
        await until { capture.state == .listening }
        capture.transcript = "with more detail"
        precondition(voice.transcript == "keep this draft with more detail")
        voice.send()
        capture.finish("with more detail")
        await until { reply != nil }
        let retryCommand = commands.last!
        reply!.resume(throwing: URLError(.networkConnectionLost)); reply = nil
        await until { !voice.isSubmitting }
        precondition(voice.needsRetry && !voice.canResume && voice.hasText)
        voice.activateTerminal("b")
        precondition(voice.targetID == "a")
        voice.send()
        await until { reply != nil }
        precondition(commands.last == retryCommand, "Retry must preserve ID, text, and destination")
        available.remove("a")
        voice.targetUnavailable("a")
        reply!.resume(); reply = nil
        await until { !voice.isSubmitting }
        available.insert("a")
        precondition(capture.state == .idle && !voice.hasText, "A late acknowledgement cannot rearm after suspension")
        print("PASS: disconnect keeps drafts, reconnect needs Resume, and uncertain delivery retries the immutable command")

        voice.resume()
        await until { capture.state == .listening }
        capture.transcript = "older send"
        voice.send()
        capture.finish("older send")
        await until { reply != nil }
        let lateReply = reply!; reply = nil
        voice.stop()
        voice.activateTerminal("b")
        await until { capture.state == .listening }
        capture.transcript = "newer draft"
        let completedBeforeReply = completedDeliveries
        let acknowledgedBeforeReply = voice.lastAcknowledgedCommand
        lateReply.resume()
        await until { completedDeliveries > completedBeforeReply }
        precondition(voice.targetID == "b" && voice.transcript == "newer draft" && capture.state == .listening)
        precondition(voice.lastAcknowledgedCommand == acknowledgedBeforeReply, "Late acknowledgements cannot steal terminal focus")
        voice.discard()
        await until { capture.state == .listening }
        precondition(!voice.hasText && voice.targetID == "b")
        voice.activateTerminal("a")
        await until { capture.state == .listening && voice.targetID == "a" }
        precondition(!voice.hasText)
        print("PASS: late delivery cannot clear a newer draft; discarding permits explicit terminal switching")

        voice.stop()
        capture.delayPermission = true
        voice.activateTerminal("a")
        await until { capture.permission != nil }
        voice.conversationEnabled = false
        let completedBeforePermission = capture.completedStarts
        capture.permission!.resume(); capture.permission = nil
        await until { capture.completedStarts > completedBeforePermission }
        precondition(voice.mode == nil && capture.state == .idle && !voice.hasText)
        precondition(voice.audioLevels.allSatisfy { $0 == 0 }, "Stopping capture must clear the waveform")
        precondition(!defaults.bool(forKey: "conversationVoiceEnabled"))
        precondition(commands.count == count + 4, "Cancellation and target switching must not submit anything")
        print("PASS: turning the setting off cancels delayed microphone preparation without sending")
    }

    @MainActor
    private static func until(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("Condition timed out")
    }
}
