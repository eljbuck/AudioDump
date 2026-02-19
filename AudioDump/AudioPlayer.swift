import AVFoundation
import Combine

/// Simple playback helper for .m4a files.
final class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    // TODO: Add transport controls (pause/skip ±15 seconds)
    private var player: AVAudioPlayer?

    @Published var isPlaying: Bool = false

    func play(url: URL) {
        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            player.play()
            self.player = player
            self.isPlaying = true
        } catch {
            // Handle playback error
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        self.player = nil
    }
}
