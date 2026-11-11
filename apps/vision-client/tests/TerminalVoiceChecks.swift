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
        let capture = FakeSpeechCapture()
        var available = Set(["a", "b"])
        var commands: [TerminalVoiceCommand] = []
        var renames: [(id: String, name: String)] = []
        var nameTargets: [TerminalVoiceController.NameTarget] = []
        var delayRename = false
        var renameReply: CheckedContinuation<Void, Error>?
        var completedRenames = 0
        var completedDeliveries = 0
        var reply: CheckedContinuation<Void, Error>?
        let voice = TerminalVoiceController(capture: capture, waitBeforeSend: {},
            isAvailable: { id, mode in available.contains(id) || (id == "legacy" && mode == .rename) },
            rename: { id, name, target in
                defer { completedRenames += 1 }
                renames.append((id, name))
                nameTargets.append(target)
                if delayRename { try await withCheckedThrowingContinuation { renameReply = $0 } }
            }, deliver: { command in
                defer { completedDeliveries += 1 }
                commands.append(command)
                try await withCheckedThrowingContinuation { reply = $0 }
            })

        voice.beginTerminalHold("a")
        await until { capture.state == .listening }
        precondition(!capture.finishOnPause)
        voice.endTerminalHold("a")
        capture.finish("one\r\nshot")
        await until { reply != nil }
        precondition(commands.last?.text == "one\nshot" && commands.last?.targetID == "a")
        reply!.resume(); reply = nil
        await until { voice.mode == nil }
        print("PASS: releasing a hold waits for final text and sends without a separate Send press")

        let restoredCapture = FakeSpeechCapture()
        let restored = TerminalVoiceController(capture: restoredCapture,
            isAvailable: { _, _ in true },
            rename: { _, _, _ in preconditionFailure("Restoration cannot rename") },
            deliver: { _ in preconditionFailure("Restoration cannot submit input") })
        precondition(restored.mode == nil && restoredCapture.starts == 0,
            "Listening and target selection do not restore")
        voice.beginTerminalHold("a")
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
        voice.beginTerminalHold("b")
        precondition(voice.targetID == "a" && voice.hasText, "A draft cannot jump to another terminal")
        voice.send()
        precondition(capture.state == .finishing && commands.count == count)
        capture.finish("second corrected segment")
        await until { reply != nil }
        precondition(commands.last?.text == "first corrected segment second corrected segment")
        precondition(commands.last?.targetID == "a")
        reply!.resume(); reply = nil
        await until { voice.mode == nil }
        precondition(capture.state == .idle && !voice.hasText && !voice.isSubmitting)
        voice.beginTerminalHold("a")
        await until { capture.state == .listening }
        print("PASS: pauses and recognition segments keep one draft; acknowledged sends stop recording")

        capture.transcript = "keep this draft"
        available.remove("a")
        voice.targetUnavailable("a")
        precondition(capture.state == .idle && voice.transcript == "keep this draft")
        available.insert("a")
        precondition(capture.state == .idle, "Reconnect cannot silently restart the microphone")
        voice.beginTerminalHold("a")
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
        voice.beginTerminalHold("b")
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
        print("PASS: disconnect keeps drafts, reconnect needs a fresh hold, and uncertain delivery retries the immutable command")

        voice.beginTerminalHold("a")
        await until { capture.state == .listening }
        capture.transcript = "older send"
        voice.send()
        capture.finish("older send")
        await until { reply != nil }
        let lateReply = reply!; reply = nil
        voice.stop()
        voice.beginTerminalHold("b")
        await until { capture.state == .listening }
        capture.transcript = "newer draft"
        let completedBeforeReply = completedDeliveries
        lateReply.resume()
        await until { completedDeliveries > completedBeforeReply }
        precondition(voice.targetID == "b" && voice.transcript == "newer draft" && capture.state == .listening)
        voice.discard()
        precondition(!voice.hasText && voice.mode == nil && capture.state == .idle)
        voice.beginTerminalHold("b")
        await until { capture.state == .listening }
        voice.beginTerminalHold("a")
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

        voice.activateRename("a", target: .workspace)
        await until { capture.state == .listening }
        capture.finish("Shared workspace")
        await until { voice.mode == nil }
        precondition(nameTargets.last == .workspace && renames.last?.name == "Shared-workspace")
        precondition(commands.count == count + 4, "Workspace naming cannot send terminal input")
        renames.removeLast()

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
        voice.beginTerminalHold("a")
        await until { capture.state == .listening }
        capture.transcript = "unsent command"
        voice.activateRename("b")
        precondition(voice.mode == .terminal && voice.targetID == "a" && voice.transcript == "unsent command")
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
        voice.beginTerminalHold("b")
        await until { capture.state == .listening }
        capture.transcript = "new draft"
        let completedBeforeRenameReply = completedRenames
        renameReply!.resume(); renameReply = nil
        await until { completedRenames > completedBeforeRenameReply }
        precondition(voice.mode == .terminal && voice.targetID == "b" && voice.transcript == "new draft")
        print("PASS: failed renames keep a retryable draft and stale acknowledgements cannot clear newer voice input")

        voice.stop()
        let renameCount = renames.count
        capture.delayPermission = true
        voice.activateRename("a")
        await until { capture.permission != nil }
        voice.stop()
        let completedBeforePermission = capture.completedStarts
        capture.permission!.resume(); capture.permission = nil
        await until { capture.completedStarts > completedBeforePermission }
        precondition(voice.mode == nil && capture.state == .idle && !voice.hasText)
        precondition(voice.audioLevels.allSatisfy { $0 == 0 }, "Stopping capture must clear the waveform")
        precondition(commands.count == count + 4, "Cancellation and target switching must not submit anything")
        precondition(renames.count == renameCount, "Late permission cannot rename a window")
        print("PASS: cancellation during delayed microphone preparation cannot send")
        voice.stop()
        capture.delayPermission = false
        voice.beginTerminalHold("legacy")
        precondition(voice.mode == nil, "A disconnected legacy renderer cannot receive dictation")
        voice.activateRename("legacy", target: .workspace)
        await until { capture.state == .listening }
        precondition(voice.targetID == "legacy" && voice.mode == .rename,
            "Metadata naming must open even when terminal input is unavailable")
        voice.stop()
        print("PASS: legacy windows can open metadata naming independently of terminal input readiness")

        var reviewed: [String] = []
        let commandCount = commands.count
        precondition(voice.activateDraft("report", onReview: { reviewed.append($0) }))
        await until { capture.state == .listening }
        precondition(!capture.finishOnPause, "A report must never submit on a pause, during composition")
        capture.finish("the preview broke")
        await until { capture.state == .listening }
        precondition(reviewed.isEmpty && commands.count == commandCount)
        capture.transcript = "after reconnecting"
        voice.send()
        capture.finish("after reconnecting to my Mac")
        precondition(reviewed == ["the preview broke after reconnecting to my Mac"] && voice.mode == nil)
        precondition(commands.count == commandCount, "Reviewing a report must not deliver terminal input")
        voice.beginTerminalHold("a")
        await until { capture.state == .listening }
        capture.transcript = "unsent terminal draft"
        precondition(!voice.activateDraft("report", onReview: { reviewed.append($0) }))
        precondition(voice.targetID == "a" && voice.transcript == "unsent terminal draft" && capture.state == .idle,
            "Opening a report pauses existing capture without discarding or redirecting its draft")
        voice.stop()
        precondition(voice.activateDraft("report", text: "edited report", onReview: { reviewed.append($0) }))
        await until { capture.state == .listening }
        voice.pause()
        precondition(voice.transcript == "edited report" && capture.state == .idle)
        voice.stop()
        capture.onFinished?()
        precondition(reviewed.count == 1 && commands.count == commandCount, "Closing the sheet cannot submit a report")
        print("PASS: report dictation shares one microphone, holds pauses, preserves terminal drafts, and only produces a local review")

        await checkRecognitionContinuity()
        await checkHoldCountdown()
        await checkReleaseDuringPreparation()
    }

    @MainActor
    private static func checkRecognitionContinuity() async {
        let capture = FakeSpeechCapture()
        var commands: [TerminalVoiceCommand] = []
        let voice = TerminalVoiceController(capture: capture, waitBeforeSend: {},
            isAvailable: { _, _ in true },
            rename: { _, _, _ in preconditionFailure("Utterance continuity must not rename") },
            deliver: { commands.append($0) })
        voice.beginTerminalHold("a")
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
        voice.beginTerminalHold("a")
        await until { capture.state == .listening }
        precondition(voice.transcript == beforeFailure)
        capture.receive("last words")
        voice.endTerminalHold("a")
        capture.receive("", hasError: true)
        await until { commands.count == 1 && voice.mode == nil }
        precondition(capture.state == .idle)
        precondition(commands[0].targetID == "a")
        precondition(commands[0].text == "Keep the entire draft. including after a long pause long recording part 1 long recording part 2 last words")
        precondition(!voice.hasText, "Only acknowledged delivery clears the terminal draft")
        voice.stop()
        print("PASS: long-recording rotations and endAudio errors keep each segment once; unsolicited failures require Resume")
    }

    @MainActor
    private static func checkHoldCountdown() async {
        let capture = FakeSpeechCapture()
        var waits: [CheckedContinuation<Void, Never>] = []
        var completedWaits = 0
        var commands: [TerminalVoiceCommand] = []
        let voice = TerminalVoiceController(capture: capture, waitBeforeSend: {
            // Deliberately finish cancelled waits too: stale timers must be inert.
            await withCheckedContinuation { waits.append($0) }
            completedWaits += 1
        }, isAvailable: { _, _ in true },
            rename: { _, _, _ in preconditionFailure("Holds cannot rename") },
            deliver: { commands.append($0) })

        voice.beginTerminalHold("a")
        await until { capture.state == .listening }
        let starts = capture.starts
        voice.beginTerminalHold("a")
        precondition(capture.starts == starts && !capture.finishOnPause)
        capture.receive("cancel this")
        voice.endTerminalHold("other")
        precondition(capture.state == .listening, "Another window cannot release this hold")
        voice.endTerminalHold("a")
        precondition(capture.state == .finishing && waits.isEmpty)
        capture.finish("Cancel this corrected draft.")
        await until { waits.count == 1 }
        precondition(voice.transcript == "Cancel this corrected draft." && commands.isEmpty)
        precondition(voice.sendDeadline!.timeIntervalSinceNow > 2.5 && !voice.canSend && !voice.canResume)
        voice.endTerminalHold("a")
        voice.send()
        precondition(waits.count == 1 && commands.isEmpty, "Repeated release or Send cannot skip the grace period")
        voice.stop() // The × button cancels the draft and countdown.
        waits[0].resume()
        await until { completedWaits == 1 }
        precondition(voice.mode == nil && voice.sendDeadline == nil && commands.isEmpty && voice.lastSubmission == nil)
        print("PASS: release finalizes corrected text, then gives three seconds to cancel with ×; cancelled timers cannot send")

        voice.beginTerminalHold("a")
        await until { capture.state == .listening }
        voice.endTerminalHold("a")
        capture.finish("")
        precondition(voice.mode == nil && waits.count == 1, "An empty hold cannot schedule Return")
        voice.beginTerminalHold("a")
        await until { capture.state == .listening }
        capture.receive("held draft")
        voice.cancelTerminalHold("a")
        capture.onFinished?()
        precondition(voice.mode == nil && !voice.hasText && commands.isEmpty, "Gesture cancellation discards without sending")

        capture.delayPermission = true
        voice.beginTerminalHold("a")
        await until { capture.permission != nil }
        voice.endTerminalHold("a")
        let completedStarts = capture.completedStarts
        capture.permission!.resume(); capture.permission = nil
        await until { capture.completedStarts > completedStarts }
        precondition(capture.state == .idle && commands.isEmpty && waits.count == 1,
            "Release during permission preparation cannot start capture or submit later")
        capture.delayPermission = false
        voice.stop()
        print("PASS: empty holds, gesture cancellation, and early release never submit or leave the microphone running")

        voice.beginTerminalHold("a")
        await until { capture.state == .listening }
        capture.receive("keep after disconnect")
        capture.finishListening() // Release coincides with the 50-second rotation.
        voice.endTerminalHold("a")
        capture.finish("keep after disconnect")
        await until { waits.count == 2 }
        voice.targetUnavailable("a")
        waits[1].resume()
        await until { completedWaits == 2 }
        precondition(voice.sendDeadline == nil && voice.hasText && commands.isEmpty && capture.state == .idle)
        voice.endTerminalHold("a")
        precondition(commands.isEmpty, "A release after disconnect cannot resurrect the countdown")
        voice.stop()

        voice.beginTerminalHold("a")
        await until { capture.state == .listening }
        capture.receive("old timer")
        voice.endTerminalHold("a")
        capture.finish("old timer")
        await until { waits.count == 3 }
        voice.stop()
        voice.beginTerminalHold("b")
        await until { capture.state == .listening }
        capture.receive("new draft")
        waits[2].resume()
        await until { completedWaits == 3 }
        precondition(voice.targetID == "b" && voice.transcript == "new draft" && commands.isEmpty)
        voice.endTerminalHold("b")
        capture.finish("new corrected draft")
        await until { waits.count == 4 }
        precondition(voice.lastSubmission == nil && commands.isEmpty, "Feedback waits for actual delivery")
        waits[3].resume()
        await until { commands.count == 1 && voice.mode == nil }
        precondition(commands[0].targetID == "b" && commands[0].text == "new corrected draft")
        precondition(voice.lastSubmission == TerminalVoiceSubmission(targetID: "b", commandID: commands[0].commandID) && capture.state == .idle)
        print("PASS: disconnects and superseded countdowns cannot send; successful delivery emits feedback and stays stopped")

        // Exercise the production clock too, so the test seam cannot hide an
        // accidental immediate submission or a different default delay.
        let timedCapture = FakeSpeechCapture()
        var sentAt: ContinuousClock.Instant?
        let timed = TerminalVoiceController(capture: timedCapture, isAvailable: { _, _ in true },
            rename: { _, _, _ in }, deliver: { _ in sentAt = .now })
        timed.beginTerminalHold("a")
        await until { timedCapture.state == .listening }
        timedCapture.receive("real countdown")
        timed.endTerminalHold("a")
        let releasedAt = ContinuousClock.now
        timedCapture.finish("real countdown")
        try? await Task.sleep(for: .seconds(2.8))
        precondition(sentAt == nil && timed.sendDeadline != nil)
        await until { sentAt != nil }
        precondition(releasedAt.duration(to: sentAt!) >= .seconds(3))
        print("PASS: the default countdown waits three full seconds before delivery")
    }

    @MainActor
    private static func checkReleaseDuringPreparation() async {
        let capture = FakeSpeechCapture()
        var commands: [TerminalVoiceCommand] = []
        let voice = TerminalVoiceController(capture: capture, waitBeforeSend: {},
            isAvailable: { _, _ in true }, rename: { _, _, _ in }, deliver: { commands.append($0) })
        voice.beginTerminalHold("a")
        await until { capture.state == .listening }
        capture.receive("preserved words")
        voice.pause()
        capture.delayPermission = true
        voice.beginTerminalHold("a")
        await until { capture.permission != nil }
        voice.endTerminalHold("a")
        await until { commands.count == 1 && voice.mode == nil }
        precondition(commands[0].text == "preserved words", "Release still schedules the draft while a new segment prepares")
        let completed = capture.completedStarts
        capture.permission!.resume(); capture.permission = nil
        await until { capture.completedStarts > completed }
        precondition(commands.count == 1 && capture.state == .idle, "Late preparation cannot rearm after release and delivery")
        print("PASS: releasing a resumed hold during preparation sends its preserved draft once and cancels late capture")
    }

    @MainActor
    private static func until(file: StaticString = #file, line: UInt = #line, _ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("Condition timed out", file: file, line: line)
    }
}
