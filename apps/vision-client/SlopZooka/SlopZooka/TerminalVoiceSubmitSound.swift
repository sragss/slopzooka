@preconcurrency import AVFAudio
import Foundation

/// Delivery feedback never performs file or audio-hardware work on the UI thread.
/// One shared click player is prepared before delivery, independently of the
/// scene-anchored terminal notification players and the capture session owner.
@MainActor
final class TerminalVoiceSubmitSound {
    private static let playback = VoiceSubmitPlayback()

    init() { _ = Self.playback }

    func play(commandID: String) {
        Self.playback.play(commandID: commandID)
    }
}

/// The queue exclusively owns the player, including preparation and playback.
nonisolated private final class VoiceSubmitPlayback: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.samragsdale.SlopZooka.voice-feedback", qos: .userInitiated)
    private var player: AVAudioPlayer?

    init() {
        queue.async { [self] in
            do { try prepare() }
            catch { report(error, event: "sound.prepare.failed") }
        }
    }

    func play(commandID: String) {
        let requestedAt = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in
            do {
                try prepare()
                player?.currentTime = 0
                guard player?.play() == true else {
                    report(nil, event: "sound.play.failed", commandID: commandID)
                    return
                }
                let elapsed = (ProcessInfo.processInfo.systemUptime - requestedAt) * 1000
                Task { @MainActor in
                    AppLog("voice-feedback").child(["commandId": commandID])
                        .info("sound.play.started", ["durationMs": String(elapsed)])
                }
            } catch { report(error, event: "sound.play.failed", commandID: commandID) }
        }
    }

    private func prepare() throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard player == nil else { return }
        guard let url = Bundle.main.url(forResource: "terminal-voice-submit", withExtension: "wav") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let prepared = try AVAudioPlayer(contentsOf: url)
        prepared.volume = 0.65
        guard prepared.prepareToPlay() else { throw CocoaError(.fileReadUnknown) }
        player = prepared
    }

    private func report(_ error: Error?, event: String, commandID: String = "") {
        Task { @MainActor in
            AppLog("voice-feedback").child(["commandId": commandID]).error(event, error: error)
        }
    }
}
