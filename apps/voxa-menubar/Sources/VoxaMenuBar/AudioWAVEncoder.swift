import AVFoundation
import Foundation

/// Owned by AudioRecorder's worker. Retains only capped, upload-ready PCM plus scratch buffers.
final class AudioWAVEncoder {
    static let sampleRate = 16_000.0
    let inputFormat: AVAudioFormat
    let maximumInputFrames: Int
    private let maximumOutputFrames: Int
    private let mono: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    private let converter: AVAudioConverter
    private var pcm = Data()
    private(set) var inputFrames = 0
    private(set) var level = 0.0

    var duration: TimeInterval { Double(inputFrames) / inputFormat.sampleRate }
    var reachedLimit: Bool { inputFrames == maximumInputFrames }

    init(format: AVAudioFormat, limit: TimeInterval) throws {
        guard limit.isFinite, (1...3600).contains(limit) else { throw AudioRecorderError.invalidLimit }
        guard Self.supports(format),
              let monoFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1),
              let outputFormat = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AudioCaptureInbox.frameCapacity),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096),
              let converter = AVAudioConverter(from: monoFormat, to: outputFormat) else {
            throw AudioRecorderError.unsupportedFormat
        }
        inputFormat = format
        maximumInputFrames = Int((limit * format.sampleRate).rounded(.down))
        maximumOutputFrames = Int((limit * Self.sampleRate).rounded(.down))
        self.mono = mono
        self.output = output
        self.converter = converter
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
    }

    static func supports(_ format: AVAudioFormat) -> Bool {
        format.commonFormat == .pcmFormatFloat32 && !format.isInterleaved
            && format.sampleRate.isFinite && (8_000...192_000).contains(format.sampleRate)
            && (1...8).contains(format.channelCount)
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.format == inputFormat, buffer.frameLength <= mono.frameCapacity,
              let channels = buffer.floatChannelData, let destination = mono.floatChannelData?[0] else {
            throw AudioRecorderError.unsupportedFormat
        }
        let count = min(Int(buffer.frameLength), maximumInputFrames - inputFrames)
        guard count > 0 else { return }
        let channelCount = Int(inputFormat.channelCount)
        var energy = 0.0
        var peak = 0.0
        for frame in 0..<count {
            var value = 0.0
            for channel in 0..<channelCount {
                let sample = channels[channel][frame]
                let finite = sample.isFinite ? Double(sample) : 0
                value += finite
                let metered = max(-1, min(1, finite))
                energy += metered * metered
                peak = max(peak, abs(metered))
            }
            let mixed = Float(max(-1, min(1, value / Double(channelCount))))
            destination[frame] = mixed
        }
        // Preserve the legacy display response: gate noise, boost speech/peaks, then
        // rise quickly and fall gently. Metering never changes the PCM sent to conversion.
        let rms = sqrt(energy / Double(count * channelCount))
        let rmsLevel = sqrt(max(0, rms - 0.003) * 20)
        let peakLevel = sqrt(max(0, peak - 0.015) * 6) * 0.8
        let target = min(1, max(rmsLevel, peakLevel))
        level += (target - level) * (target > level ? 0.55 : 0.18)
        mono.frameLength = AVAudioFrameCount(count)
        inputFrames += count
        try convert(input: mono, ending: false)
    }

    func finish() throws -> Data {
        guard inputFrames > 0 else { throw AudioRecorderError.noAudio }
        // End-of-stream drains resampler tail frames; noDataNow between buffers must not reset it.
        try convert(input: nil, ending: true)
        let length = UInt32(pcm.count)
        var wav = Data("RIFF".utf8)
        wav.appendLittleEndian(length + 36)
        wav.append(Data("WAVEfmt ".utf8))
        wav.appendLittleEndian(UInt32(16))
        wav.appendLittleEndian(UInt16(1)) // PCM
        wav.appendLittleEndian(UInt16(1)) // mono
        wav.appendLittleEndian(UInt32(Self.sampleRate))
        wav.appendLittleEndian(UInt32(Self.sampleRate * 2))
        wav.appendLittleEndian(UInt16(2))
        wav.appendLittleEndian(UInt16(16))
        wav.append(Data("data".utf8))
        wav.appendLittleEndian(length)
        wav.append(pcm)
        return wav
    }

    private func convert(input: AVAudioPCMBuffer?, ending: Bool) throws {
        var supplied = false
        // Even the largest supported input block needs fewer than 32 output blocks.
        for _ in 0..<64 {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, status in
                if !supplied, let input {
                    supplied = true
                    status.pointee = .haveData
                    return input
                }
                status.pointee = ending ? .endOfStream : .noDataNow
                return nil
            }
            guard status != .error else { throw error ?? AudioRecorderError.conversionFailed as NSError }
            if let samples = output.floatChannelData?[0] {
                let count = min(Int(output.frameLength), maximumOutputFrames - pcm.count / 2)
                for index in 0..<count {
                    let sample = samples[index].isFinite ? max(-1, min(1, samples[index])) : 0
                    pcm.appendLittleEndian(Int16((sample * Float(Int16.max)).rounded()))
                }
            }
            if status == .endOfStream || (!ending && status == .inputRanDry) { return }
        }
        throw AudioRecorderError.conversionFailed
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
