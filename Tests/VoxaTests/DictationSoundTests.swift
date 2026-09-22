#if canImport(XCTest) || VOXA_STANDALONE_TESTS
import AVFoundation
import Foundation
#if !VOXA_STANDALONE_TESTS
import XCTest
@testable import Voxa
#endif

private struct SoundCheckFailure: Error, CustomStringConvertible {
    let description: String
}

private enum DictationSoundChecks {
    static func bundledZenAudio() throws {
        var recordings = Set<Data>()
        for cue in DictationSoundCue.allCases {
            guard let url = DictationSoundAssets.url(for: cue) else {
                throw SoundCheckFailure(description: "Missing bundled Zen cue: \(cue)")
            }
            recordings.insert(try Data(contentsOf: url))
            let player = try AVAudioPlayer(contentsOf: url)
            guard player.numberOfChannels == 1, player.duration > 0, player.duration < 1 else {
                throw SoundCheckFailure(description: "Zen cue must be mono, brief, and nonempty: \(cue)")
            }

            let file = try AVAudioFile(forReading: url)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(file.length)) else {
                throw SoundCheckFailure(description: "Cannot allocate decoded audio buffer")
            }
            try file.read(into: buffer)
            guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else {
                throw SoundCheckFailure(description: "Zen cue did not decode: \(cue)")
            }
            let samples = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
            let peak = samples.map { abs($0) }.max() ?? 0
            guard samples.allSatisfy(\.isFinite), peak * cue.volume > 0.005,
                  peak * cue.volume < 0.25 else {
                throw SoundCheckFailure(description: "Zen cue is silent, invalid, or too loud: \(cue)")
            }
        }
        guard recordings.count == DictationSoundCue.allCases.count else {
            throw SoundCheckFailure(description: "Start, stop, and error must have distinct audio")
        }
    }
}

#if VOXA_STANDALONE_TESTS
@main
struct DictationSoundTestRunner {
    static func main() throws {
        try DictationSoundChecks.bundledZenAudio()
        print("Zen audio checks passed: bundled start, stop, and error decode at safe playback levels.")
    }
}
#else
final class DictationSoundTests: XCTestCase {
    func testBundledZenAudioDecodesAtQuietLevels() throws {
        try DictationSoundChecks.bundledZenAudio()
    }
}
#endif
#endif
