import Foundation

@main
struct LabModelChecks {
    @MainActor static func main() async throws {
        let lab = LabModel()
        precondition(lab.arrangement == .split && lab.dictation == .hold && lab.session == .connected)

        lab.selectSession(.readOnly)
        lab.submitKeyboard("ignored")
        lab.interrupt()
        precondition(lab.output.isEmpty && lab.session.acceptsControls)
        lab.selectSession(.connected)
        lab.submitKeyboard("pwd")
        lab.interrupt()
        precondition(lab.output == ["> pwd", "⎋ Interrupted"])

        lab.reload()
        precondition(lab.session == .connecting)
        lab.selectSession(.disconnected)
        try await Task.sleep(for: .milliseconds(650))
        precondition(lab.session == .disconnected, "A late reload must not replace a selected scenario.")

        lab.stageVoice(.partial)
        try await until { lab.voice.transcript == FixtureSpeechCapture.partial }
        lab.voice.endTerminalHold(LabModel.terminalID)
        try await until { lab.voice.sendDeadline != nil }
        precondition(lab.voice.transcript == FixtureSpeechCapture.full)
        lab.selectSession(.disconnected)
        precondition(lab.voice.sendDeadline == nil && lab.voice.hasText)
        try await Task.sleep(for: .milliseconds(2100))
        precondition(lab.output.count == 2, "Disconnect must cancel the pending delivery.")

        lab.stageVoice(.countdown)
        try await until { lab.voice.sendDeadline != nil }
        lab.stopVoice()
        precondition(lab.voice.targetID == nil && lab.voice.sendDeadline == nil)
        try await Task.sleep(for: .milliseconds(2100))
        precondition(lab.output.count == 2, "The X must cancel the pending delivery.")

        lab.stageVoice(.denied)
        try await until { lab.voice.statusText.contains("permission was denied") }
        lab.stageVoice(.retry)
        try await until(seconds: 4) { lab.voice.needsRetry }
        precondition(lab.output.count == 2 && lab.voice.hasText)
        lab.voice.send()
        try await until { lab.output.last == "> " + FixtureSpeechCapture.full }
        precondition(lab.output.count == 3)

        lab.selectDictation(.review)
        lab.stageVoice(.retry)
        try await until { lab.reviewDeliveryFailed }
        precondition(lab.reviewReady && lab.voice.hasText && lab.output.count == 3)
        lab.sendReview()
        precondition(lab.output.count == 4 && lab.voice.targetID == nil)

        lab.stageVoice(.long)
        try await until { lab.voice.transcript == FixtureSpeechCapture.long }
        lab.selectSession(.disconnected)
        precondition(lab.reviewReady && lab.voice.hasText)
        lab.sendReview()
        precondition(lab.output.count == 4)
        lab.selectSession(.connected)
        lab.resumeReview()
        try await until { lab.voice.captureState == .listening }
        lab.closeTerminal()
        precondition(!lab.terminalVisible && lab.voice.targetID == nil)

        lab.reset()
        precondition(lab.output.isEmpty && lab.session == .connected && lab.dictation == .review)
        print("PASS: fixture input, reload cancellation, voice disconnect, denial, retry, review, and close")
    }

    @MainActor private static func until(seconds: Int = 2, _ ready: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while !ready() {
            precondition(clock.now < deadline, "Fixture did not reach the expected state.")
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
