#if os(visionOS)
import AVFAudio
import Foundation

/// Each terminal owns a player explicitly anchored to its native scene. Do not
/// change the shared audio session's anchor: dictation and other windows share it.
@MainActor
final class TerminalNotificationSound {
    private var player: AVAudioPlayer?
    private var lastPlayed = Date.distantPast

    func play(sceneID: String) {
        // A burst of bells is one cue; each window has its own throttle.
        guard Date().timeIntervalSince(lastPlayed) >= 1 else { return }
        do {
            if player == nil {
                guard let url = Bundle.main.url(forResource: "terminal-notification", withExtension: "wav") else {
                    slzLog("notification sound resource missing")
                    return
                }
                player = try AVAudioPlayer(contentsOf: url)
                player?.volume = 0.5
            }
            player?.intendedSpatialExperience = .headTracked(.scene(identifier: sceneID))
            player?.currentTime = 0
            if player?.play() == true { lastPlayed = Date() }
        } catch {
            slzLog("notification sound failed: \(error.localizedDescription)")
        }
    }
}
#endif
