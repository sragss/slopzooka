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
    private var segment = SpeechRecognitionSegment()

    func startListening(finishOnPause: Bool) async {
        defer { completedStarts += 1 }
        guard recording == nil else { preconditionFailure("Two microphone owners") }
        let id = UUID()
        recording = id
        starts += 1
        self.finishOnPause = finishOnPause
        segment = SpeechRecognitionSegment()
        transcript = ""
        state = .preparing
        if delayPermission { await withCheckedContinuation { permission = $0 } }
        guard recording == id else { return }
        state = .listening
    }
    func finishListening() { state = .finishing }
    func stopListening() { recording = nil; audioLevels = Array(repeating: 0, count: 5); state = .idle }
    func clearTranscript() { transcript = "" }
    func receive(_ text: String, isFinal: Bool = false, hasUtteranceMetadata: Bool = false, hasError: Bool = false) {
        let finished = segment.receive(text, isFinal: isFinal, hasUtteranceMetadata: hasUtteranceMetadata,
            isFinishing: state == .finishing, hasError: hasError)
        transcript = segment.transcript
        if finished {
            stopListening()
            onFinished?()
        } else if hasError {
            stopListening()
            state = .failed("Recognition failed")
        }
    }
    func finish(_ text: String) { receive(text, isFinal: true) }
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
        var renames: [(id: String, name: String)] = []
        var delayRename = false
        var renameReply: CheckedContinuation<Void, Error>?
        var completedRenames = 0
        var completedDeliveries = 0
        var reply: CheckedContinuation<Void, Error>?
        let voice = TerminalVoiceController(capture: capture, defaults: defaults,
            isAvailable: { available.contains($0) },
            rename: {
                defer { completedRenames += 1 }
                renames.append(($0, $1))
                if delayRename { try await withCheckedThrowingContinuation { renameReply = $0 } }
            }, deliver: { command in
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
            isAvailable: { _ in true },
            rename: { _, _ in preconditionFailure("Restoration cannot rename") },
            deliver: { _ in preconditionFailure("Restoration cannot submit input") })
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
        voice.activateRename("b")
        await until { capture.state == .listening }
        precondition(voice.mode == .rename && capture.finishOnPause, "Rename always uses one-shot capture")
        capture.finish("  Fix\t the\nlogin\u{00a0}flow  ")
        await until { voice.mode == nil }
        precondition(voice.mode == nil && capture.state == .idle)
        precondition(renames.count == 1 && renames[0].id == "b" && renames[0].name == "Fix-the-login-flow")
        precondition(commands.count == count + 4, "Naming must never deliver terminal input")

        voice.activateRename("a")
        await until { capture.state == .listening }
        capture.transcript = "partial"
        voice.send()
        precondition(capture.state == .finishing && renames.count == 1)
        capture.finish("Final name")
        await until { voice.mode == nil }
        precondition(renames.last?.name == "Final-name" && renames.last?.id == "a")
        voice.activateRename("a")
        await until { capture.state == .listening }
        capture.finish(" \n ")
        precondition(renames.count == 2 && voice.canResume, "Empty speech cannot replace a name")
        voice.resume()
        await until { capture.state == .listening }
        capture.transcript = "keep until reconnect"
        voice.targetUnavailable("a")
        precondition(renames.count == 2 && voice.transcript == "keep until reconnect")
        voice.stop()
        voice.activateTerminal("a")
        await until { capture.state == .listening }
        capture.transcript = "unsent command"
        voice.activateRename("b")
        precondition(voice.mode == .conversation && voice.targetID == "a" && voice.transcript == "unsent command")
        print("PASS: rename starts capture, normalizes whitespace, waits for final text, and never submits terminal input")

        voice.stop()
        delayRename = true
        voice.activateRename("a")
        await until { capture.state == .listening }
        capture.finish("Retry this name")
        await until { renameReply != nil }
        renameReply!.resume(throwing: URLError(.networkConnectionLost)); renameReply = nil
        await until { !voice.isSubmitting }
        precondition(voice.mode == .rename && voice.hasText && voice.canSend)
        voice.send()
        await until { renameReply != nil }
        precondition(renames.suffix(2).allSatisfy { $0.id == "a" && $0.name == "Retry-this-name" })
        renameReply!.resume(); renameReply = nil
        await until { voice.mode == nil }
        voice.activateRename("a")
        await until { capture.state == .listening }
        capture.finish("Older rename")
        await until { renameReply != nil }
        voice.stop()
        voice.activateTerminal("b")
        await until { capture.state == .listening }
        capture.transcript = "new draft"
        let completedBeforeRenameReply = completedRenames
        renameReply!.resume(); renameReply = nil
        await until { completedRenames > completedBeforeRenameReply }
        precondition(voice.mode == .conversation && voice.targetID == "b" && voice.transcript == "new draft")
        print("PASS: failed renames keep a retryable draft and stale acknowledgements cannot clear newer voice input")

        voice.stop()
        let renameCount = renames.count
        capture.delayPermission = true
        voice.activateRename("a")
        await until { capture.permission != nil }
        voice.conversationEnabled = false
        let completedBeforePermission = capture.completedStarts
        capture.permission!.resume(); capture.permission = nil
        await until { capture.completedStarts > completedBeforePermission }
        precondition(voice.mode == nil && capture.state == .idle && !voice.hasText)
        precondition(voice.audioLevels.allSatisfy { $0 == 0 }, "Stopping capture must clear the waveform")
        precondition(!defaults.bool(forKey: "conversationVoiceEnabled"))
        precondition(commands.count == count + 4, "Cancellation and target switching must not submit anything")
        precondition(renames.count == renameCount, "Late permission cannot rename a window")
        print("PASS: turning the setting off cancels delayed microphone preparation without sending")
        await checkRecognitionContinuity(defaults: defaults)
    }

    @MainActor
    private static func checkRecognitionContinuity(defaults: UserDefaults) async {
        let capture = FakeSpeechCapture()
        var commands: [TerminalVoiceCommand] = []
        let voice = TerminalVoiceController(capture: capture, defaults: defaults,
            isAvailable: { _ in true },
            rename: { _, _ in preconditionFailure("Utterance continuity must not rename") },
            deliver: { commands.append($0) })
        voice.conversationEnabled = true
        voice.activateTerminal("a")
        await until { capture.state == .listening }

        capture.receive("keep the entire draft with extra words")
        capture.receive("keep the entire draft")
        precondition(voice.transcript == "keep the entire draft", "Corrections replace the current hypothesis")
        capture.receive("")
        precondition(voice.transcript == "keep the entire draft", "Empty partial results cannot erase words")
        var starts = capture.starts
        capture.receive("Keep the entire draft.", hasUtteranceMetadata: true)
        await until { capture.starts > starts && capture.state == .listening }
        precondition(voice.transcript == "Keep the entire draft." && commands.isEmpty,
            "Utterance metadata without isFinal commits the text and rearms without sending")
        capture.receive("including after a long pause")
        starts = capture.starts
        capture.finish("")
        await until { capture.starts > starts && capture.state == .listening }
        precondition(voice.transcript == "Keep the entire draft. including after a long pause",
            "An empty final result keeps both the committed and current utterances")
        print("PASS: on-device utterance boundaries and empty results keep the draft across pauses")

        precondition(!SpeechRecognitionSegment.shouldRotate(elapsed: 49.9))
        precondition(SpeechRecognitionSegment.shouldRotate(elapsed: 50))
        for index in 1...2 {
            capture.receive("long recording part \(index)")
            // The backend ends audio before the task limit, then completes with
            // the last nonempty hypothesis if the final callback is empty.
            capture.finishListening()
            starts = capture.starts
            if index == 1 { capture.finish("") }
            else { capture.receive("", hasError: true) }
            await until { capture.starts > starts && capture.state == .listening }
            precondition(commands.isEmpty && voice.hasText, "Task rotation must never send or discard the draft")
        }
        let beforeFailure = voice.transcript
        starts = capture.starts
        capture.receive("", hasError: true)
        precondition(voice.transcript == beforeFailure && capture.state == .failed("Recognition failed"))
        precondition(capture.starts == starts && commands.isEmpty && voice.canResume,
            "An unsolicited recognition failure keeps the draft and requires explicit Resume")
        voice.resume()
        await until { capture.state == .listening }
        precondition(voice.transcript == beforeFailure)
        capture.receive("last words")
        voice.send()
        capture.receive("", hasError: true)
        await until { commands.count == 1 && !voice.isSubmitting && capture.state == .listening }
        precondition(commands[0].targetID == "a")
        precondition(commands[0].text == "Keep the entire draft. including after a long pause long recording part 1 long recording part 2 last words")
        precondition(!voice.hasText, "Only acknowledged explicit Send clears the conversation draft")
        voice.stop()
        print("PASS: long-recording rotations and endAudio errors keep each segment once; unsolicited failures require Resume")
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
