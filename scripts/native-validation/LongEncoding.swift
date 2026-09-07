import AVFoundation
import Darwin
import Foundation

@main
private enum LongEncoding {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        for channel in 0..<2 {
            for frame in 0..<4096 {
                buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 48_000) * 0.1)
            }
        }
        let encoder = try AudioWAVEncoder(format: format, limit: 3600)
        let started = DispatchTime.now().uptimeNanoseconds
        var remaining = 3600 * 48_000
        while remaining > 0 {
            buffer.frameLength = AVAudioFrameCount(min(remaining, 4096))
            try encoder.append(buffer)
            remaining -= Int(buffer.frameLength)
        }
        // Extra input must not extend the cap or allocate another retained recording.
        buffer.frameLength = 4096
        try encoder.append(buffer)
        let wav = try encoder.finish()
        guard encoder.reachedLimit, encoder.duration == 3600, wav.count == 115_200_044 else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw CocoaError(.fileReadUnknown) }
        let report: [String: Any] = [
            "synthetic_audio_seconds": 3600, "input_rate": 48_000, "input_channels": 2,
            "wav_bytes": wav.count, "elapsed_ms": Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000,
            "peak_process_rss_bytes": usage.ru_maxrss,
            "limitations": ["Accelerated encoder-only test using one reused synthetic input buffer",
                "No microphone, UI, network upload, credentials or retained raw hour of input",
                "Peak RSS includes the harness/frameworks and simultaneous PCM/WAV data at finish",
                "Not a real-hour device reliability test or full-app peak-memory measurement"]
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("PASS: one-hour encoding cap and extra-input rejection; \(wav.count) WAV bytes")
    }
}
