import AVFAudio
import Foundation

/// A short mechanical click accompanies acknowledged voice delivery. It shares
/// the app's audio session without changing capture or notification routing.
@MainActor
final class TerminalVoiceSubmitSound {
    private let log = AppLog("voice-feedback")
    private var player: AVAudioPlayer?

    func play() {
        do {
            if player == nil {
                guard let url = Bundle.main.url(forResource: "terminal-voice-submit", withExtension: "wav") else {
                    log.error("sound.missing")
                    return
                }
                player = try AVAudioPlayer(contentsOf: url)
                player?.volume = 0.65
            }
            player?.currentTime = 0
            player?.play()
        } catch {
            log.error("sound.failed", error: error)
        }
    }
}
