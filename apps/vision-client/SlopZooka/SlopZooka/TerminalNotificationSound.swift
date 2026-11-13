#if os(visionOS)
import AVFAudio
import Foundation

/// Each terminal owns a player explicitly anchored to its native scene. Do not
/// change the shared audio session's anchor: dictation and other windows share it.
@MainActor
final class TerminalNotificationSound {
    private let log = AppLog("terminal-notification-sound")
    private var player: AVAudioPlayer?
    private var lastPlayed = Date.distantPast

    func play(sceneID: String) {
        // A burst of bells is one cue; each window has its own throttle.
        guard Date().timeIntervalSince(lastPlayed) >= 1 else { return }
        let log = self.log.child(["sceneId": sceneID])
        do {
            if player == nil {
                guard let url = Bundle.main.url(forResource: "terminal-notification", withExtension: "wav") else {
                    log.error("resource.missing")
                    return
                }
                player = try AVAudioPlayer(contentsOf: url)
                player?.volume = 0.5
            }
            player?.intendedSpatialExperience = .headTracked(.scene(identifier: sceneID))
            player?.currentTime = 0
            if player?.play() == true { lastPlayed = Date() }
            else { log.warn("playback.rejected") }
        } catch {
            log.error("playback.failed", error: error)
        }
    }
}
#endif
