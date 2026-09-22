import AVFoundation
import Foundation

/// UI SFX Zen cues. Original assets and their CC0 license live in Resources/Sounds/Zen.
enum DictationSoundCue: CaseIterable {
    case listeningStarted
    case recordingEnded
    case error

    var assetName: String {
        switch self {
        case .listeningStarted: return "start"
        case .recordingEnded: return "stop"
        case .error: return "error"
        }
    }

    /// About 3 dB above UI SFX's defaults for clearer feedback.
    var volume: Float {
        switch self {
        case .listeningStarted, .recordingEnded: return 0.27
        case .error: return 0.31
        }
    }
}

enum DictationSoundAssets {
    static func url(for cue: DictationSoundCue) -> URL? {
        // Packaged Voxa and the standalone overlay preview carry normal app resources.
        if let url = Bundle.main.url(
            forResource: cue.assetName, withExtension: "mp3", subdirectory: "Sounds/Zen"
        ) {
            return url
        }
        // swift run and SwiftPM tests use the generated resource bundle instead.
        #if SWIFT_PACKAGE
        return Bundle.module.url(
            forResource: cue.assetName, withExtension: "mp3", subdirectory: "Sounds/Zen"
        )
        #else
        return nil
        #endif
    }
}

/// Used from the app's main queue. Players retain decoded Zen audio between cues.
final class DictationSoundController {
    private var players: [DictationSoundCue: AVAudioPlayer] = [:]
    private var currentPlayer: AVAudioPlayer?

    init() {
        for cue in DictationSoundCue.allCases {
            _ = preparedPlayer(for: cue)
        }
    }

    func play(_ cue: DictationSoundCue) {
        guard let player = preparedPlayer(for: cue) else { return }
        // A fast press/release fades the previous gesture without cutting its waveform.
        if let previous = currentPlayer, previous !== player {
            previous.setVolume(0, fadeDuration: 0.012)
        } else if currentPlayer === player {
            player.stop()
        }
        player.currentTime = 0
        player.setVolume(cue.volume, fadeDuration: 0)
        currentPlayer = player
        if !player.play() {
            // Retry player creation on the next gesture after an output route failure.
            players.removeValue(forKey: cue)
            currentPlayer = nil
        }
    }

    private func preparedPlayer(for cue: DictationSoundCue) -> AVAudioPlayer? {
        if let player = players[cue] { return player }
        guard let url = DictationSoundAssets.url(for: cue),
              let player = try? AVAudioPlayer(contentsOf: url),
              player.prepareToPlay()
        else {
            // Audio feedback is optional; the overlay still reflects the real state.
            return nil
        }
        players[cue] = player
        return player
    }
}
