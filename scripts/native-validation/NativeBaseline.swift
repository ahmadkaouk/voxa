import AppKit
import AVFoundation
import Foundation

private func milliseconds(_ start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

private func require(_ condition: Bool) throws {
    if !condition { throw CocoaError(.validationMissingMandatoryProperty) }
}

private func encode(seconds: Int, format: AVAudioFormat, buffer: AVAudioPCMBuffer) throws -> Data {
    let encoder = try AudioWAVEncoder(format: format, limit: TimeInterval(seconds))
    var remaining = seconds * 48_000
    while remaining > 0 {
        buffer.frameLength = AVAudioFrameCount(min(remaining, Int(buffer.frameCapacity)))
        try encoder.append(buffer)
        remaining -= Int(buffer.frameLength)
    }
    let result = try encoder.finish()
    try require(result.count == 44 + seconds * 32_000)
    return result
}

@main
private enum NativeBaseline {
    static func main() {
        guard CommandLine.arguments.count == 4,
              let endpoint = URL(string: CommandLine.arguments[3]),
              endpoint.host == "127.0.0.1", endpoint.scheme == "http" else { exit(2) }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixture = URL(fileURLWithPath: CommandLine.arguments[2])
        Task { @MainActor in
            do {
                let conversion = try await Task.detached { () throws -> [Double] in
                    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
                    for channel in 0..<2 {
                        for frame in 0..<4096 {
                            buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 48_000) * 0.1)
                        }
                    }
                    var timings: [Double] = []
                    for sample in 0..<33 {
                        let start = DispatchTime.now().uptimeNanoseconds
                        let wav = try encode(seconds: 10, format: format, buffer: buffer)
                        let elapsed = milliseconds(start)
                        try require(wav.prefix(4) == Data("RIFF".utf8))
                        if sample >= 3 { timings.append(elapsed) }
                    }
                    return timings
                }.value
                let audio = try Data(contentsOf: fixture)
                try require(audio.count == 320_044)
                let client = TranscriptionClient(endpoint: endpoint)
                var upload: [Double] = []
                for sample in 0..<33 {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let text = try await client.transcribe(audio, model: .gptTranscribe, apiKey: "fixture-only")
                    let elapsed = milliseconds(start)
                    try require(text == "fixture transcript")
                    if sample >= 3 { upload.append(elapsed) }
                }
                let board = NSPasteboard.withUniqueName()
                defer { board.releaseGlobally() }
                let output = TranscriptOutput(paste: { text, _ in
                    ClipboardAutopaster(pasteboard: board).paste(text) { _ in
                        onPasteboardThread { board.string(forType: .string) } == "fixture transcript"
                    }
                })
                var delivery: [Double] = []
                for sample in 0..<33 {
                    board.clearContents()
                    board.setString("baseline original", forType: .string)
                    let start = DispatchTime.now().uptimeNanoseconds
                    let result = await output.deliver("fixture transcript", mode: .clipboardAutopaste)
                    let elapsed = milliseconds(start)
                    try require(result == .paste(.restored) && board.string(forType: .string) == "baseline original")
                    if sample >= 3 { delivery.append(elapsed) }
                }
                await output.drain()
                let report: [String: Any] = [
                    "kind": "native_fixture", "build": "swiftc -O, macOS 13 target", "sample_count": 30,
                    "warmup_samples_excluded": 3, "response_delay_ms": 50, "settling_delay_ms": 500,
                    "metrics_ms": ["normalization": conversion, "loopback_upload_and_response": upload,
                                   "pasteboard_read_and_restore": delivery],
                    "limitations": ["No microphone, real speech, Keychain or external API",
                        "Conversion includes native metering and AVAudioConverter; the legacy resampler differs",
                        "Conversion repeats a generated stereo tone buffer; not a bit-identical legacy input",
                        "Upload uses the exact saved stage 1 WAV bytes",
                        "Output uses an isolated pasteboard with simulated consumption; no real paste shortcut"]
                ]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: folder.appendingPathComponent("fixture-metrics.json"))
                print("Native fixture measurements complete: 30 samples per metric")
                exit(0)
            } catch { fputs("Native measurement failed: \(error)\n", stderr); exit(1) }
        }
        RunLoop.main.run()
    }
}
